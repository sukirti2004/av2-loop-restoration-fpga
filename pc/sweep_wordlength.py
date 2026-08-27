#!/usr/bin/env python3
"""
Fixed-point word-length sweep for the PC restoration filter.

Pure software study - no FPGA, no PYNQ overlay. It answers, in the OUTPUT
domain (dB of Y-PSNR against the HR source), the question the coefficient-error
figure can only answer in the parameter domain:

    how much output quality does each quantization decision actually cost?

Four configurations are evaluated per (sequence, QP):

  float        float64 taps, float thresholds       - infinite-precision bound
  taps@B       taps quantized to B fractional bits, thresholds float
  thr@Q2.14    taps float, thresholds at the shipped Q2.14
  shipped      taps Q3.13 + thresholds Q2.14        - what the RTL does

Comparing `taps@13` against `thr@Q2.14` separates the two error sources. The
arithmetic in the fixed path mirrors pc_golden.py (and therefore the RTL)
exactly; only TAP_SCALE / TAP_SHIFT are swept.

Usage
-----
    python3 sweep_wordlength.py --datasets <OUTPUT dir> --npz pc_qp_group_1.npz
"""
import argparse, os, sys, time
import numpy as np

# ── RTL constants (identical to pc_golden.py) ────────────────────────────────
FEAT_SCALE, FEAT_SHIFT, FEAT_ROUND = 21049, 13, 4096
THR_SCALE = 16384                       # Q2.14, as written to AXI-Lite

RESOLUTIONS = {
    'CrowdRun_1920x1080p50':        (1920, 1080),
    'OldTownCross_1920x1080p50':    (1920, 1080),
    'PedestrianArea_1920x1080p25':  (1920, 1080),
    'Riverbed_1920x1080p25':        (1920, 1080),
    'RushFieldCuts_1920x1080_2997': (1920, 1080),
}
TEST_SEQUENCES = list(RESOLUTIONS)
QPS   = ['160', '170', '180']           # pc_qp_group_1.npz training range
FRAME = '013'
RANGE = 'RANGE_1'


def load_y(path, W, H):
    return np.fromfile(path, dtype=np.uint8).reshape(H, W)


def psnr(a, b):
    d = a.astype(np.float64) - b.astype(np.float64)
    mse = float((d * d).mean())
    return float('inf') if mse == 0 else 10.0 * np.log10(255.0 ** 2 / mse)


# ── feature + context stage (shared; features are integer-exact either way) ──
def compute_ctx(a, r0, r1, W, thresholds, thr_is_int):
    """Directional Laplacian features -> packed 12-bit context index."""
    def S(dy, dx):
        return a[r0 + dy:r1 + dy, 3 + dx:W - 3 + dx]

    shape = (r1 - r0, W - 6)
    sums = [np.zeros(shape, dtype=np.int32) for _ in range(4)]
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            c2 = 2 * S(dy, dx)
            sums[0] += np.abs(-S(dy,     dx - 1) + c2 - S(dy,     dx + 1))
            sums[1] += np.abs(-S(dy - 1, dx)     + c2 - S(dy + 1, dx))
            sums[2] += np.abs(-S(dy - 1, dx - 1) + c2 - S(dy + 1, dx + 1))
            sums[3] += np.abs(-S(dy - 1, dx + 1) + c2 - S(dy + 1, dx - 1))

    ctx = np.zeros(shape, dtype=np.int32)
    for d, s in enumerate(sums):
        if thr_is_int:
            # exactly the RTL: Q2.14 feature, integer compare
            f = ((s * FEAT_SCALE + FEAT_ROUND) >> FEAT_SHIFT) & 0xFFFF
        else:
            # infinite-precision feature, float compare
            f = s.astype(np.float64) * (FEAT_SCALE / (1 << FEAT_SHIFT))
        lv = np.zeros(shape, dtype=np.int32)
        for t in thresholds:
            lv += (f >= t)
        ctx |= lv << (3 * d)
    return ctx


def filter_frame(img, cluster_map, taps, thresholds,
                 thr_is_int, tap_shift, block_rows=270):
    """taps: (256,49) int (fixed, needs tap_shift) or float64 (tap_shift=None)."""
    H, W = img.shape
    out = img.copy()
    a = img.astype(np.int32)
    fixed = tap_shift is not None
    rnd = (1 << (tap_shift - 1)) if fixed else 0

    for r0 in range(3, H - 3, block_rows):
        r1 = min(r0 + block_rows, H - 3)

        def S(dy, dx):
            return a[r0 + dy:r1 + dy, 3 + dx:W - 3 + dx]

        ctx = compute_ctx(a, r0, r1, W, thresholds, thr_is_int)
        fid = cluster_map[ctx]

        acc = np.zeros((r1 - r0, W - 6), dtype=np.int64 if fixed else np.float64)
        for k in range(49):
            r, c = divmod(k, 7)
            acc += taps[fid, k] * S(r - 3, c - 3)

        if fixed:
            out[r0:r1, 3:W - 3] = np.clip((acc + rnd) >> tap_shift, 0, 255).astype(np.uint8)
        else:
            out[r0:r1, 3:W - 3] = np.clip(np.rint(acc), 0, 255).astype(np.uint8)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--datasets', required=True)
    ap.add_argument('--npz',      required=True)
    ap.add_argument('--out',      default='sweep_results.npz')
    ap.add_argument('--bits',     default='6,7,8,9,10,11,12,13,14,16')
    args = ap.parse_args()

    bit_list = [int(b) for b in args.bits.split(',')]

    d = np.load(args.npz)
    LUT_f = d['LUT'].astype(np.float64)
    T_f   = d['T'].astype(np.float64)
    cmap  = d['cluster_map'].astype(np.int32)
    T_int = np.round(T_f * THR_SCALE).astype(np.int32)

    rows = []
    t_start = time.time()

    for seq in TEST_SEQUENCES:
        W, H = RESOLUTIONS[seq]
        hr_p = os.path.join(args.datasets, seq, 'TEST_HR', f'frame_{FRAME}.y')
        if not os.path.exists(hr_p):
            print(f"  skip {seq}: no HR", file=sys.stderr); continue
        hr = load_y(hr_p, W, H)

        for qp in QPS:
            pre_p = os.path.join(args.datasets, seq, 'TEST_PRELR', RANGE,
                                 f'frame_{FRAME}_qp{qp}_prelr.yuv')
            if not os.path.exists(pre_p):
                print(f"  skip {seq} qp{qp}", file=sys.stderr); continue
            pre = load_y(pre_p, W, H)
            p_pre = psnr(pre, hr)

            # (1) infinite-precision reference
            o = filter_frame(pre, cmap, LUT_f, T_f, False, None)
            p_float = psnr(o, hr)

            # (2) thresholds quantized, taps float -> classifier error alone
            o = filter_frame(pre, cmap, LUT_f, T_int, True, None)
            p_thr = psnr(o, hr)

            # (3) tap word-length sweep, thresholds float -> datapath error alone
            p_taps = {}
            for b in bit_list:
                tq = np.round(LUT_f * (1 << b)).astype(np.int64)
                o = filter_frame(pre, cmap, tq, T_f, False, b)
                p_taps[b] = psnr(o, hr)

            # (4) shipped: Q3.13 taps + Q2.14 thresholds (must equal the RTL)
            tq13 = np.round(LUT_f * 8192).astype(np.int64)
            o = filter_frame(pre, cmap, tq13, T_int, True, 13)
            p_ship = psnr(o, hr)

            rows.append(dict(seq=seq, qp=qp, pre=p_pre, float=p_float,
                             thr=p_thr, shipped=p_ship, taps=p_taps))
            print(f"{seq:30s} qp{qp}  pre={p_pre:6.3f}  float={p_float:6.3f}  "
                  f"thrQ2.14={p_thr:6.3f}  shipped={p_ship:6.3f}  "
                  f"[{time.time()-t_start:5.0f}s]", flush=True)

    np.savez(args.out, rows=np.array(rows, dtype=object),
             bits=np.array(bit_list))
    print(f"\nwrote {args.out}  ({len(rows)} runs, {time.time()-t_start:.0f}s)")


if __name__ == '__main__':
    main()
