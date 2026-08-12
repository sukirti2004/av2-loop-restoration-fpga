# PC Filter — Hardware Implementation Summary

**Target device:** Xilinx Zynq-7020 (`xc7z020clg400-1`), PYNQ-Z2 board
**Tool:** Vivado 2025.2
**Clock:** 100 MHz (`FCLK_CLK0` from PS7)
**Status:** Implemented, timing met, bitstream written, validated on hardware

---

## 1. System architecture

```
        PS (ARM Cortex-A9, PYNQ / Python)
                    │
        ┌───────────┴────────────┐
        │ AXI-Lite (M_AXI_GP0)   │  thresholds t0–t6, img dimensions
        │ AXI-DMA  (S_AXI_HP0)   │  pixel stream in/out
        └───────────┬────────────┘
                    │
                    ▼
              axi_dma_0
        MM2S ──────────────► pc_filter_0 (S00_AXIS)
        S2MM ◄────────────── pc_filter_0 (M00_AXIS)
```

The PL block accepts one 8-bit luma pixel per clock over AXI-Stream, filters it,
and returns one filtered pixel per clock. Pixels travel in bits `[7:0]` of a
32-bit `TDATA` bus.

---

## 2. Filter datapath

```
pixel_in (1 px/clk)
    │
    ▼
line_buffer            6 BRAMs, 7×7 shift register        2 clk
    │ pixels_flat (49×8)
    ▼
feature_compute        4 directional Laplacian features    4 clk
    │ feat0–3 (Q2.14 signed)
    ▼
quantizer_ctx          4 feats × 8 levels → 12-bit ctx     1 clk
    │ ctx (12-bit)
    ▼
cluster_lut            4096 × 8-bit BRAM lookup            1 clk
    │ filter_id (8-bit)
    ▼
filter_lut             256 × 784-bit BRAM lookup           1 clk
    │ taps_flat (49 × Q3.13)
    ▼
mac_engine             49-tap MAC, 49 × DSP48E1            5 clk
    │
    ▼
pixel_out (8-bit, clipped [0,255])

Pixel delay chain: 7 stages, gated on valid, aligns pixels with their taps
Total pipeline latency: 12 clocks
```

### Module detail

| Module | Function | Latency | Key resources |
|---|---|---|---|
| `line_buffer` | 7×7 sliding window extraction, 2-phase BRAM write | 2 clk | 6 × BRAM18, ~470 FF |
| `feature_compute` | Mean \|Laplacian\| in H/V/D/A directions, Q2.14 | 4 clk | 4 × DSP, ~1100 FF |
| `quantizer_ctx` | Threshold comparison → 12-bit context index | 1 clk | LUT logic |
| `cluster_lut` | Context → filter ID (4096 entries) | 1 clk | 1 × BRAM |
| `filter_lut` | Filter ID → 49 taps (256 × 784-bit) | 1 clk | ~4 × BRAM36 |
| `mac_engine` | 49 multiplies + adder tree, `>>13`, clip | 5 clk | 49 × DSP |

### Fixed-point formats

| Quantity | Format | Notes |
|---|---|---|
| Pixels | uint8 | `[0, 255]` |
| Features | Q2.14 signed | scaled by `×21049 >> 13` ≈ 1/(25·255) |
| Thresholds | Q2.14 | written at runtime over AXI-Lite |
| Filter taps | Q3.13 signed int16 | `round(tap_float × 8192)` |
| MAC output | `clip(sum >> 13, 0, 255)` | truncating shift |

---

## 3. Resource utilization (post-implementation)

| Resource | Used | Available | Utilization |
|---|---|---|---|
| LUT | 6,173 | 53,200 | **11.60 %** |
| LUTRAM | 361 | 17,400 | 2.07 % |
| FF | 6,202 | 106,400 | 5.83 % |
| BRAM | 11 | 140 | 7.86 % |
| **DSP** | **61** | 220 | **27.73 %** |
| BUFG | 1 | 32 | 3.13 % |

DSP is the dominant resource: 49 for the MAC multiplies, 4 for feature scaling,
the remainder absorbed from adder logic and the frame-size multiply.

The design leaves substantial headroom — roughly 3× the DSP budget remains,
which is the relevant constraint for scaling to multi-component or
higher-throughput variants.

---

## 4. Timing

| Metric | Value |
|---|---|
| **Worst Negative Slack (setup)** | **+0.107 ns** |
| Total Negative Slack | 0.000 ns |
| Worst Hold Slack | +0.017 ns |
| Total Hold Slack | 0.000 ns |
| Worst Pulse Width Slack | +3.750 ns |
| Failing endpoints | **0** of 19,676 |

**All user-specified timing constraints are met** at 100 MHz.

Slack is tight (+0.107 ns, ~1 % of the 10 ns period). Closure required
splitting both the MAC adder tree and the feature-compute sum across additional
pipeline stages — see the timing-closure notes in the NS implementation guide.

---

## 5. Power

| Metric | Value |
|---|---|
| Total on-chip power | 1.698 W |
| Junction temperature | 44.6 °C |
| Thermal margin | 40.4 °C (3.4 W) |
| Effective θJA | 11.5 °C/W |
| Estimate confidence | Medium |

Comfortable thermal headroom; no active cooling required.

---

## 6. Throughput

| Metric | Value |
|---|---|
| Pixel rate | 1 pixel/clock @ 100 MHz = **100 Mpixel/s** |
| 1080p frame (2.07 Mpixel) | **~20.7 ms** compute |
| Theoretical 1080p frame rate | **~48 fps** |
| Measured end-to-end (incl. DMA) | ~320 ms/frame |

The gap between compute time and measured latency is DMA transfer and PYNQ
buffer overhead, not the filter. The PL datapath sustains one pixel per clock
with no stalls.

---

## 7. Interfaces

### AXI-Lite register map (base `0x43C00000`)

| Offset | Register | Contents |
|---|---|---|
| `0x00` | slv_reg0 | threshold t0 (Q2.14, bits `[15:0]`) |
| `0x04` | slv_reg1 | threshold t1 |
| `0x08` | slv_reg2 | threshold t2 |
| `0x0C` | slv_reg3 | threshold t3 |
| `0x10` | slv_reg4 | threshold t4 |
| `0x14` | slv_reg5 | threshold t5 |
| `0x18` | slv_reg6 | threshold t6 |
| `0x1C` | slv_reg7 | `img_height[26:16]` \| `img_width[10:0]` |

### AXI-Stream

| Interface | Width | Notes |
|---|---|---|
| `S00_AXIS` (in) | 32-bit | pixel in `TDATA[7:0]`; `TREADY` tied high |
| `M00_AXIS` (out) | 32-bit | pixel in `TDATA[7:0]`; `TLAST` on final interior pixel |

`TLAST` is generated by a pixel counter against `(img_width−6) × (img_height−6)`,
supplied from the AXI-Lite dimension register.

---

## 8. Design decisions and limitations

**Luma only.** The datapath is single-channel 8-bit. Chroma planes pass through
unmodified. This matches the reference design's scope.

**Interior-only output.** The filter emits `(H−6) × (W−6)` pixels — a 3-pixel
border cannot form a complete 7×7 window. Border pixels are copied from the
input on the PS side.

**No input backpressure.** `S_AXIS_TREADY` is tied high. The pipeline accepts
one pixel every clock unconditionally, so it never needs to stall an upstream
DMA. Valid for offline batch processing; a real-time source feeding faster than
100 Mpixel/s would require a proper ready path.

**LUTs baked into the bitstream.** `cluster_lut` and `filter_lut` load their
contents via `$readmemh` at synthesis time. Changing the trained model therefore
requires a full re-synthesis (~1 hour). Only the thresholds are runtime-writable.
Adding a BRAM write port over AXI-Lite would make model swaps take seconds —
worth doing if models will be iterated frequently.

**Absolute paths in `$readmemh`.** `cluster_lut.v` and `filter_lut.v` reference
`E:/ELIM_NonSeparable_V2_0/vivado/fpga_pc/*.hex` by absolute path. The project
will not build on another machine without editing these. Adding the hex files as
project sources and using relative paths would fix this.

**Truncation rather than rounding.** The MAC applies `>> 13` directly. Adding
`+4096` before the shift would round to nearest and remove a ~0.5 LSB bias
(measured MAE 0.48 vs the golden model). Functionally negligible but trivial to
correct if bit-exactness matters.

---

## 9. Verification status

| Check | Result |
|---|---|
| Constant-image test | Exact ✓ |
| Horizontal ramp | Exact ✓ |
| Vertical ramp | Exact ✓ |
| Spatial alignment scan (±8 px) | Best match at (0, 0) ✓ |
| MAE vs Python golden model | 0.48 (sub-LSB, truncation) |
| 90-frame hardware sweep | Completed, results in `PC_Filter_PSNR_Results.md` |

The implementation reproduces its golden model to within one least-significant
bit across natural video content.
