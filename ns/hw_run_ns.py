"""hw_run_ns.py — end-to-end NS filter validation on PYNQ (memory-safe).

Same flow as before, but the trainer now accumulates 24x24 and 24x1 moments
row-strip by row-strip, never materializing the full patch matrix. Peak RAM
~50 MB for a 1080p frame, fits comfortably in the PYNQ-Z2's 512 MB DDR.

  1. Load one pre-LR frame + matching HR ground truth (raw Y planes).
  2. Compute 7-bit quantized taps (single tap set for whole frame = one giant RU).
  3. Load taps into the FPGA IP, stream frame through DMA.
  4. Apply the same integer taps in pure Python (golden fixed-point model).
  5. Compare HW vs Python golden; report PSNR vs HR.

Dependencies: numpy only. No scipy/sklearn/PIL/yaml.
"""
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

# ============================================================================
# Support geometry (from ns_pc/ns_filter.py)
# ============================================================================
PATCH_SIZE = 7
HALF = 3
FILTER_SIZE = 49
DEFAULT_NS_RIDGE = 0.01
DEFAULT_MIN_SUM  = 0.05
DEFAULT_BITS_PER_TAP = 7
DEFAULT_MAX_QUANT_PASSES = 20


def diamond_23_mask():
    mask = np.zeros((7, 7), dtype=bool)
    for r, cols in [
        (0, [3]), (1, [2, 3, 4]), (2, [1, 2, 3, 4, 5]),
        (3, [1, 2, 3, 4, 5]), (4, [1, 2, 3, 4, 5]),
        (5, [2, 3, 4]), (6, [3]),
    ]:
        mask[r, cols] = True
    return mask.ravel()


def ns_support_basis(mask):
    mask = np.asarray(mask, dtype=bool).ravel()
    N_full = mask.size
    mask_indices = np.where(mask)[0]
    pos_in_mask  = {int(i): k for k, i in enumerate(mask_indices)}
    seen, cols = set(), []
    for i in mask_indices:
        i = int(i)
        if i in seen:
            continue
        j = N_full - 1 - i
        col = np.zeros(mask_indices.size, dtype=np.float32)
        col[pos_in_mask[i]] = 1.0
        if j != i:
            col[pos_in_mask[j]] = 1.0
        cols.append(col)
        seen.add(i); seen.add(j)
    return np.stack(cols, axis=1)


# ============================================================================
# Chunked moment accumulation — never allocates the full patch matrix.
# ============================================================================
def accumulate_moments(sr_uint8, hr_uint8, mask, chunk_rows=32):
    """Row-strip through the frame, accumulate:
        M_xx = Xm.T @ Xm     (n_cells, n_cells)
        M_xy = Xm.T @ y      (n_cells,)
        yy   = sum(y**2)     (scalar)
        N    = number of patches
    Memory per strip: chunk_rows*W*49*8 bytes ~= 30 MB at chunk_rows=32, W=1920.
    """
    H, W = sr_uint8.shape
    n_cells = int(mask.sum())

    sr = sr_uint8.astype(np.float32) / 255.0
    hr = hr_uint8.astype(np.float32) / 255.0
    sr_padded = np.pad(sr, HALF, mode="symmetric")

    M_xx = np.zeros((n_cells, n_cells), dtype=np.float64)
    M_xy = np.zeros(n_cells,             dtype=np.float64)
    yy = 0.0
    N  = 0

    for r0 in range(0, H, chunk_rows):
        r1 = min(r0 + chunk_rows, H)
        slab = sr_padded[r0 : r1 + 2 * HALF, :]              # (r1-r0+2*HALF, W+2*HALF)
        win  = sliding_window_view(slab, (PATCH_SIZE, PATCH_SIZE))
        chunk = win[: r1 - r0, : W].reshape(-1, FILTER_SIZE) # (chunk_rows*W, 49)
        Xm = chunk[:, mask].astype(np.float64)               # (chunk_rows*W, n_cells)
        yv = hr[r0:r1].ravel().astype(np.float64)            # (chunk_rows*W,)

        M_xx += Xm.T @ Xm
        M_xy += Xm.T @ yv
        yy   += float(yv @ yv)
        N    += yv.size

        # help GC
        del slab, win, chunk, Xm, yv

    return M_xx, M_xy, yy, N


# ============================================================================
# KKT continuous solve, driven from precomputed moments.
# ============================================================================
def solve_ns_continuous_from_moments(M_xx, M_xy, basis,
                                     ridge=DEFAULT_NS_RIDGE,
                                     min_unit_sum=DEFAULT_MIN_SUM):
    """A = basis.T @ M_xx @ basis;  b = basis.T @ M_xy.  Then KKT solve."""
    A = basis.T @ M_xx @ basis
    if ridge > 0:
        A = A + ridge * np.eye(A.shape[0], dtype=A.dtype)
    b = basis.T @ M_xy

    K_ = A.shape[0]
    w = basis.sum(axis=0).astype(A.dtype)
    KKT = np.zeros((K_ + 1, K_ + 1), dtype=A.dtype)
    KKT[:K_, :K_] = A
    KKT[:K_, K_]  = w
    KKT[K_, :K_]  = w
    rhs = np.zeros(K_ + 1, dtype=A.dtype)
    rhs[:K_] = b
    rhs[K_]  = 1.0
    try:
        sol = np.linalg.solve(KKT, rhs)
    except np.linalg.LinAlgError:
        return None, "singular"
    f_unique = sol[:K_]
    f_mask = (basis @ f_unique).astype(np.float32)
    if abs(float(f_mask.sum())) < min_unit_sum:
        return None, "zero_sum"
    return f_mask, "ok"


# ============================================================================
# 7-bit CD quantizer, driven from moments only (no patch matrix needed).
# ============================================================================
def quantize_ns_7bit_from_moments(f_cont_mask, M_xx, M_xy, yy, N, basis,
                                  bits_per_tap=DEFAULT_BITS_PER_TAP,
                                  max_passes=DEFAULT_MAX_QUANT_PASSES):
    """Same coordinate-descent as ns_filter.py, but MSE computed from moments:
        MSE(f) = ( yy - 2*f.T @ (basis.T @ M_xy) / s + f.T @ (basis.T @ M_xx @ basis) @ f / s^2 ) / N
    where s = w @ f and f is scaled by 1/scale.
    All operations on 12x12 matrices — no memory issues.
    """
    K = basis.shape[1]
    A_K = basis.T @ M_xx @ basis          # (K, K), tiny
    b_K = basis.T @ M_xy                  # (K,)
    w   = basis.sum(axis=0).astype(np.float64)

    rep_idx = np.array([int(np.argmax(basis[:, k])) for k in range(K)])
    f_unique_cont = f_cont_mask[rep_idx].astype(np.float64)

    max_int = 2 ** (bits_per_tap - 1) - 1
    scale = max_int / max(np.max(np.abs(f_unique_cont)), 1e-12)
    f_int = np.round(f_unique_cont * scale).astype(np.int64)
    f_int = np.clip(f_int, -max_int, max_int)

    def _mse(fint):
        f_real = fint.astype(np.float64) / scale
        s = float(w @ f_real)
        if abs(s) < 1e-6:
            return float("inf")
        # MSE = (yy - 2*(f/s).T @ b_K + (f/s).T @ A_K @ (f/s)) / N
        fs = f_real / s
        return float((yy - 2.0 * fs @ b_K + fs @ A_K @ fs) / N)

    best_mse = _mse(f_int)
    n_improvements = 0
    passes = 0
    for pass_idx in range(max_passes):
        passes = pass_idx + 1
        improved = False
        for k in range(K):
            best_delta = 0
            for d in (-1, +1):
                trial = f_int.copy()
                trial[k] = np.clip(trial[k] + d, -max_int, max_int)
                if trial[k] == f_int[k]:
                    continue
                m = _mse(trial)
                if m < best_mse - 1e-12:
                    best_mse = m
                    best_delta = d
            if best_delta != 0:
                f_int[k] = np.clip(f_int[k] + best_delta, -max_int, max_int)
                improved = True
                n_improvements += 1
        if not improved:
            break

    weighted_sum = int(2 * np.sum(f_int[:K-1]) + f_int[K-1])
    norm_q16 = 0 if weighted_sum == 0 else int(round(65536.0 / weighted_sum)) & 0xFFFF
    return f_int.astype(np.int8), norm_q16, {
        "K": K, "scale": float(scale), "final_mse": best_mse,
        "passes": passes, "n_improvements": n_improvements,
        "weighted_sum_int": weighted_sum,
    }


def train_single_ru_taps(sr_uint8, hr_uint8,
                         ridge=DEFAULT_NS_RIDGE, chunk_rows=32):
    """Train ONE tap set for whole frame (memory-safe chunked accumulation)."""
    assert sr_uint8.shape == hr_uint8.shape
    mask = diamond_23_mask()
    basis = ns_support_basis(mask)

    M_xx, M_xy, yy, N = accumulate_moments(sr_uint8, hr_uint8, mask, chunk_rows)

    f_cont, status = solve_ns_continuous_from_moments(M_xx, M_xy, basis, ridge)
    if f_cont is None:
        raise RuntimeError(f"Continuous solve failed: {status}")
    f_int, norm_q16, qstats = quantize_ns_7bit_from_moments(
        f_cont, M_xx, M_xy, yy, N, basis)
    qstats["status"] = status
    return f_int, norm_q16, qstats


# ============================================================================
# Python golden — apply same integer taps with RTL-matching fixed-point math.
# Chunked to keep peak RAM low. Peak here ~50 MB.
# ============================================================================
def _pair_positions_from_basis(basis, mask):
    mask_indices = np.where(mask)[0]
    K = basis.shape[1]
    pairs = []
    for k in range(K):
        rows = np.where(basis[:, k] == 1.0)[0]
        pairs.append([int(mask_indices[r]) for r in rows])
    return pairs


def apply_taps_python_golden(sr_uint8, f_int, norm_q16, mask, basis):
    """acc = sum_k f_int[k] * (sum_positions src) ; out = (acc*norm+32768)>>16."""
    H, W = sr_uint8.shape
    pairs = _pair_positions_from_basis(basis, mask)
    src = np.pad(sr_uint8, HALF, mode="symmetric").astype(np.int32)
    acc = np.zeros((H, W), dtype=np.int64)
    for k, positions in enumerate(pairs):
        pair_sum = np.zeros((H, W), dtype=np.int32)
        for p in positions:
            dr, dc = p // 7 - HALF, p % 7 - HALF
            pair_sum += src[HALF+dr : HALF+dr+H, HALF+dc : HALF+dc+W]
        acc += int(f_int[k]) * pair_sum
        del pair_sum
    del src
    scaled = (acc * int(norm_q16) + (1 << 15)) >> 16
    return np.clip(scaled, 0, 255).astype(np.uint8)


# ============================================================================
# Hardware I/O
# ============================================================================
def reset_dma(dma):
    import time
    mm = dma.mmio
    mm.write(0x00, 0x4); mm.write(0x30, 0x4)
    time.sleep(0.01)
    mm.write(0x00, 0x1); mm.write(0x30, 0x1)
    dma.sendchannel._first_transfer = True
    dma.recvchannel._first_transfer = True


def write_taps_to_ip(ns, f_int, norm_q16):
    for i in range(12):
        ns.write(i * 4, int(f_int[i]) & 0x7F)
    ns.write(0x30, int(norm_q16) & 0xFFFF)


def run_hw_frame(ns, dma, sr_uint8, f_int, norm_q16):
    from pynq import allocate
    import time
    H, W = sr_uint8.shape
    write_taps_to_ip(ns, f_int, norm_q16)
    ns.write(0x34, W)
    ns.write(0x38, H)
    in_buf  = allocate(shape=(H*W,),     dtype=np.uint32)
    out_buf = allocate(shape=((H-6)*W,), dtype=np.uint32)
    in_buf[:] = sr_uint8.flatten().astype(np.uint32)
    reset_dma(dma)
    t0 = time.time()
    dma.recvchannel.transfer(out_buf)
    ns.write(0x3C, 1)
    dma.sendchannel.transfer(in_buf)
    dma.sendchannel.wait()
    dma.recvchannel.wait()
    dt = time.time() - t0
    beats = ns.read(0x00); flags = ns.read(0x04)
    print(f"  HW: {dt*1000:.1f} ms, beats={beats}, tlast={(flags>>3)&1}")
    out = (out_buf & 0xFF).reshape((H-6, W)).astype(np.uint8)
    del in_buf, out_buf
    return out


# ============================================================================
# End-to-end validation
# ============================================================================
def validate_frame(ns, dma, prelr_path, hr_path, H=1080, W=1920):
    import time, gc
    print(f"=== Validating {prelr_path.split('/')[-1]} ===")

    prelr = np.fromfile(prelr_path, dtype=np.uint8).reshape(H, W)
    hr    = np.fromfile(hr_path,    dtype=np.uint8).reshape(H, W)
    print(f"Loaded pre-LR + HR : {H}x{W}, uint8")

    print("Training NS taps (chunked accumulator + KKT + 7-bit CD)...")
    t0 = time.time()
    f_int, norm_q16, stats = train_single_ru_taps(prelr, hr, chunk_rows=32)
    print(f"  train time: {time.time()-t0:.2f} s")
    print(f"  taps (int7):      {f_int.tolist()}")
    print(f"  weighted_sum_int: {stats['weighted_sum_int']}")
    print(f"  norm_q16:         0x{norm_q16:04X}  ({norm_q16})")
    print(f"  CD passes: {stats['passes']}, improvements: {stats['n_improvements']}")

    gc.collect()

    print("Running on FPGA...")
    hw_out = run_hw_frame(ns, dma, prelr, f_int, norm_q16)

    print("Applying same taps in Python (golden)...")
    t0 = time.time()
    mask  = diamond_23_mask()
    basis = ns_support_basis(mask)
    py_out_full = apply_taps_python_golden(prelr, f_int, norm_q16, mask, basis)
    print(f"  Python apply: {time.time()-t0:.2f} s")
    py_interior = py_out_full[3:H-3, :]

    diff = hw_out.astype(np.int16) - py_interior.astype(np.int16)
    print(f"HW vs Python golden:")
    print(f"  max |diff|:  {int(np.abs(diff).max())}")
    print(f"  mean |diff|: {float(np.abs(diff).mean()):.3f}")
    print(f"  exact match: {float((diff == 0).mean())*100:.2f}%")

    hr_interior    = hr[3:H-3, :].astype(np.int32)
    prelr_interior = prelr[3:H-3, :].astype(np.int32)
    def _psnr(a, b):
        mse = float(np.mean((a.astype(np.int32) - b) ** 2))
        return float("inf") if mse == 0 else 10 * np.log10(255**2 / mse)
    psnr_prelr = _psnr(prelr_interior, hr_interior)
    psnr_hw    = _psnr(hw_out,         hr_interior)
    psnr_py    = _psnr(py_interior,    hr_interior)
    print(f"PSNR vs HR (interior only):")
    print(f"  pre-LR   : {psnr_prelr:.3f} dB   (baseline)")
    print(f"  HW NS    : {psnr_hw:.3f} dB   (delta: {psnr_hw - psnr_prelr:+.3f})")
    print(f"  Python NS: {psnr_py:.3f} dB   (delta: {psnr_py - psnr_prelr:+.3f})")

    return {
        "f_int": f_int, "norm_q16": norm_q16,
        "hw_out": hw_out, "py_out": py_out_full,
        "hr": hr, "prelr": prelr,
        "psnr_prelr": psnr_prelr, "psnr_hw": psnr_hw, "psnr_py": psnr_py,
    }


if __name__ == "__main__":
    from pynq import Overlay
    ol  = Overlay("ns_filter_bd_wrapper.bit")
    ns  = ol.ns_filter_0
    dma = ol.axi_dma_0
    PRELR = "/home/xilinx/jupyter_notebooks/pc_filter/TreesAndGrass_1920_1080_30fps_8bit/TEST_PRELR/RANGE_1/frame_014_qp160_prelr.yuv"
    HR    = "/home/xilinx/jupyter_notebooks/pc_filter/TreesAndGrass_1920_1080_30fps_8bit/TEST_HR/frame_014.y"
    result = validate_frame(ns, dma, PRELR, HR)
