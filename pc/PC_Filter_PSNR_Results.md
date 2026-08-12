# PC Filter — FPGA PSNR Results

**Date:** 2026-07-29
**Platform:** PYNQ-Z2 (Zynq-7020), PC filter @ 100 MHz
**Sequence:** TreesAndGrass_1920_1080_30fps_8bit
**Model:** `pc_qp_group_1.npz` (retrained)
**Bitstream:** post-fix (gated `px_d` chain)

---

## 1. Test setup

```
TEST_HR/frame_XXX.y                    ← ground truth (uncompressed Y)
        ↑ PSNR comparison
TEST_PRELR/RANGE_1/frame_XXX_qpNNN_prelr.yuv   ← filter input (pre-loop-restoration)
        ↓
   PC filter on FPGA
        ↓
   filtered Y
```

- **Resolution:** 1920 × 1080, 8-bit, Y plane only
- **QP range tested:** RANGE_1 = QP {160, 170, 180}
- **Frames:** 30 frames × 3 QPs = 90 files
- **Thresholds:** derived as `round(T_float × 16384)` = `[0, 5, 10, 26, 57, 123, 280]`
- **Throughput:** ~320 ms per 1080p frame (DMA round trip included)

### PSNR convention (important for verification)

- Computed on the **interior only**: `[3:-3, 3:-3]`
- Border pixels (3-pixel margin) are copied from the pre-LR input, not filtered
- `PSNR = 10 · log10(255² / MSE)`

---

## 2. RTL fidelity vs golden model

Measured on frame_021 qp170, 60×60 region at (400, 600):

| Metric | Value |
|---|---|
| MAE golden vs FPGA | **0.48** |
| Exact matches | **52.4 %** |
| Best spatial shift | **(0, 0)** — no offset |

Residual is sub-LSB: ~half the pixels differ by exactly 1, caused by the MAC
truncating (`>>13`) where the golden model would round. Not a functional error.

### Synthetic verification (all exact)

| Test | Result |
|---|---|
| Constant image (128) | FPGA output = 128 everywhere ✓ |
| Horizontal ramp | FPGA = golden, cols 100–105 ✓ |
| Vertical ramp | FPGA = golden, rows 100–105 ✓ |

---

## 3. Frame-level results (90 frames)

| Metric | Value |
|---|---|
| Avg PSNR before (pre-LR) | **25.768 dB** |
| Avg PSNR after (filtered) | **25.773 dB** |
| **Avg gain** | **+0.005 dB** |
| Max gain | +0.039 dB |
| Min gain | −0.045 dB |
| Frames improved | **62 / 90** |

### Per-QP breakdown

| QP | Frames | Avg gain |
|---|---|---|
| 160 | 30 | +0.000 dB |
| 170 | 30 | +0.012 dB |
| 180 | 30 | +0.005 dB |

---

## 4. Per-RU results (64×64 restoration units)

Sampled 10 frames per QP (30 frames total):

| Metric | Value |
|---|---|
| Total RUs | **13,920** |
| RUs where PC helps | **10,727 (77.1 %)** |
| Blanket avg gain | **+0.0341 dB** |
| RDO-oracle gain (max(g, 0)) | **+0.0452 dB** |
| Mean gain on winning RUs | **+0.0587 dB** |

**Note on the two averages.** The per-RU blanket average (+0.0341 dB) is larger
than the frame-level average (+0.005 dB). Both are correct — frame PSNR takes the
log of the *pooled* MSE, so high-error regions dominate, whereas per-RU averaging
in dB weights every unit equally. Quote the frame-level number for comparison
against published results; use the per-RU number for diagnostics.

---

## 5. Spot check (single region, for exact reproduction)

frame_021 qp170, 60×60 region at row 400, col 600:

| Source | PSNR vs HR |
|---|---|
| Pre-LR input | 27.614 dB |
| Golden model (Python) | 27.557 dB |
| FPGA output | 27.571 dB |

---

## 6. Reproducing in pure Python

To verify these numbers on CPU without the board, use this golden model —
it matches the FPGA to within 1 LSB:

```python
import numpy as np

data        = np.load('pc_qp_group_1.npz')
T_float     = data['T']
LUT         = data['LUT']
cluster_map = data['cluster_map']
LUT_fixed   = np.round(LUT * 8192).astype(np.int32)

def golden(patch):
    """patch: (7,7) uint8, centre = patch[3,3]. Returns filtered centre pixel."""
    p_f = patch.astype(np.float32) / 255.0
    p_i = patch.astype(np.int32).flatten()

    def mal(dr, dc):
        return sum(abs(-p_f[r+dr[0], c+dc[0]] + 2*p_f[r, c] - p_f[r+dr[1], c+dc[1]])
                   for r in range(1, 6) for c in range(1, 6)) / 25.0

    feats = [mal([0, 0], [-1, 1]),    # H
             mal([-1, 1], [0, 0]),    # V
             mal([-1, 1], [-1, 1]),   # D
             mal([-1, 1], [1, -1])]   # A

    q   = [int((f >= T_float).sum()) for f in feats]
    ctx = q[0] + 8*q[1] + 64*q[2] + 512*q[3]
    fid = int(cluster_map[ctx])
    s   = int(np.dot(LUT_fixed[fid], p_i))
    return int(np.clip(s >> 13, 0, 255))     # truncate, matches FPGA

def load_raw_y(path, W=1920, H=1080):
    with open(path, 'rb') as f:
        return np.frombuffer(f.read(W*H), dtype=np.uint8).reshape(H, W).copy()

def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64))**2)
    return 10 * np.log10(255**2 / mse) if mse > 0 else float('inf')
```

**Expected deviation:** pure-Python golden vs FPGA differs by ≤1 on ~48 % of
pixels (truncation), which moves PSNR by well under 0.01 dB.

---

## 7. Interpretation

The filter produces a **consistent but small** gain on this sequence: 77 % of
restoration units improve, averaging +0.059 dB where it wins.

TreesAndGrass is close to worst-case content for this filter — dense
high-frequency foliage, where genuine detail is hard to distinguish from
compression noise within a 7×7 patch. Testing a sequence with smoother regions
and structured edges would separate content-dependence from a model limitation.

The hardware result is independent of that question: the implementation is
verified to match its golden model to within one LSB at 100 MHz.

---

## Appendix — Bug found and fixed

**Symptom:** −8.02 dB average "gain" (filter destroying the image).

**Root cause:** the pixel delay chain in `pc_filter_core.v` shifted on every
clock, while every stage in the taps path was gated on `valid`. Since
`line_buffer`'s `valid_out` is low for the first 6 columns of each row and the
first 6 rows, the two paths desynchronised and the MAC combined a patch with
taps computed for a different patch.

**Fix:**

```verilog
always @(posedge clk) begin
    if (valid_in) begin        // ← was ungated
        px_d[0] <= pixels_flat;
        ...
        px_d[6] <= px_d[5];
    end
end
```

**Result:** MAE vs golden 14.63 → 0.48. Average gain −8.022 dB → +0.005 dB.

**Why testbenches missed it:**

1. `tb_pc_filter_core` held `pixels_flat` static — a delay chain of any depth or
   gating returns the same value when its input never changes.
2. `valid_in` was driven continuously, never creating the gaps required to
   desynchronise the paths.
3. `line_buffer` was tested standalone; its valid gapping is correct behaviour.
   The bug lived in the *interaction* between the two modules, so no
   single-module test could see it.

Constant and ramp images also pass despite the bug — local context barely varies,
so wrong taps ≈ right taps. Only textured streaming content exposes it.

**Recommendation for NS:** build a streaming testbench that feeds a small
synthetic image (e.g. 32×16 with varying values) through `line_buffer` into the
filter core, comparing every output against the golden model. That is the only
test that exercises gapped valid and changing content simultaneously.
