#!/usr/bin/env python3
"""
Fixed-point word-length sweep for the PC restoration filter.

Produces the data behind Fig. 4 of the paper (plot with fig_wordlength.py).
Pure software study -- no FPGA, no PYNQ overlay. It answers, in the OUTPUT
domain (dB of Y-PSNR against the HR source), how much output quality each
quantization decision actually costs.

UNITS -- the one thing to get right here. The feature is carried in Q2.14,
i.e. sum_of_25_|Laplacian| x 2^14 / (25*255), range 0..32760. The thresholds
as stored in the .npz are raw floats in [0,1], range 0..0.017. They MUST be
scaled by 2^14 before any comparison. Comparing a Q2.14 feature against a
raw threshold makes every nonzero feature exceed all seven thresholds, which
silently collapses the classifier to a single filter and invalidates every
number downstream. Both paths below compare against T_int (Q2.14 integers).

Configurations per (sequence, QP):
  pre        pre-loop-restoration input
  float      float64 taps + exact-scale classifier   <- infinite-precision bound
  taps@B     taps at B fractional bits + exact-scale classifier
  shipped    Q3.13 taps + RTL integer classifier     <- what the RTL does
  cls        float64 taps + RTL integer classifier   <- classifier error alone
"""
import argparse, os, sys, time
import numpy as np

FEAT_SCALE, FEAT_SHIFT, FEAT_ROUND = 21049, 13, 4096   # RTL constants
EXACT = 16384.0 / 6375.0                                # true Q2.14 feature scale
THR_SCALE = 16384                                       # thresholds -> Q2.14

RESOLUTIONS = {
    'CrowdRun_1920x1080p50':        (1920, 1080),
    'OldTownCross_1920x1080p50':    (1920, 1080),
    'PedestrianArea_1920x1080p25':  (1920, 1080),
    'Riverbed_1920x1080p25':        (1920, 1080),
    'RushFieldCuts_1920x1080_2997': (1920, 1080),
}
QPS, FRAME, RANGE = ['160', '170', '180'], '013', 'RANGE_1'


def load_y(p, W, H):
    return np.fromfile(p, dtype=np.uint8).reshape(H, W)


def psnr(a, b):
    d = a.astype(np.float64) - b.astype(np.float64)
    mse = float((d * d).mean())
    return float('inf') if mse == 0 else 10.0 * np.log10(255.0 ** 2 / mse)


def compute_ctx(a, r0, r1, W, T_int, exact):
    """T_int is ALWAYS Q2.14 integer. exact=True -> infinite-precision feature."""
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
        f = (s.astype(np.float64) * EXACT if exact
             else ((s * FEAT_SCALE + FEAT_ROUND) >> FEAT_SHIFT) & 0xFFFF)
        lv = np.zeros(shape, dtype=np.int32)
        for t in T_int:
            lv += (f >= t)
        ctx |= lv << (3 * d)
    return ctx


def filter_frame(img, cmap, taps, T_int, exact, tap_shift, block_rows=270):
    H, W = img.shape
    out = img.copy()
    a = img.astype(np.int32)
    fixed = tap_shift is not None
    rnd = (1 << (tap_shift - 1)) if fixed else 0

    for r0 in range(3, H - 3, block_rows):
        r1 = min(r0 + block_rows, H - 3)

        def S(dy, dx):
            return a[r0 + dy:r1 + dy, 3 + dx:W - 3 + dx]

        fid = cmap[compute_ctx(a, r0, r1, W, T_int, exact)]
        acc = np.zeros((r1 - r0, W - 6), dtype=np.int64 if fixed else np.float64)
        for k in range(49):
            r, c = divmod(k, 7)
            acc += taps[fid, k] * S(r - 3, c - 3)

        out[r0:r1, 3:W - 3] = (np.clip((acc + rnd) >> tap_shift, 0, 255).astype(np.uint8)
                               if fixed else np.clip(np.rint(acc), 0, 255).astype(np.uint8))
    return out


def dc_gain(taps_q, b):
    """Max |row sum - 1| over the 256 filters after quantizing to b frac bits."""
    return float(np.abs(taps_q.sum(axis=1) / float(1 << b) - 1.0).max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--datasets', required=True)
    ap.add_argument('--npz',      required=True)
    ap.add_argument('--out',      default='sweep_fixed.npz')
    ap.add_argument('--bits',     default='6,7,8,9,10,11,12,13,14,16')
    args = ap.parse_args()

    bits = [int(b) for b in args.bits.split(',')]
    d = np.load(args.npz)
    LUT_f = d['LUT'].astype(np.float64)
    cmap  = d['cluster_map'].astype(np.int32)
    T_int = np.round(d['T'].astype(np.float64) * THR_SCALE).astype(np.int32)

    dc = {b: dc_gain(np.round(LUT_f * (1 << b)).astype(np.int64), b) for b in bits}
    print('DC-gain error (max |row sum - 1|) after tap quantization:')
    for b in bits:
        print(f'   {b:2d} bits : {dc[b]*100:7.3f} %')
    print()

    rows, t0 = [], time.time()
    for seq, (W, H) in RESOLUTIONS.items():
        hr_p = os.path.join(args.datasets, seq, 'TEST_HR', f'frame_{FRAME}.y')
        if not os.path.exists(hr_p):
            print(f'  skip {seq}', file=sys.stderr); continue
        hr = load_y(hr_p, W, H)

        for qp in QPS:
            pre_p = os.path.join(args.datasets, seq, 'TEST_PRELR', RANGE,
                                 f'frame_{FRAME}_qp{qp}_prelr.yuv')
            if not os.path.exists(pre_p):
                print(f'  skip {seq} qp{qp}', file=sys.stderr); continue
            pre = load_y(pre_p, W, H)

            p_pre   = psnr(pre, hr)
            p_float = psnr(filter_frame(pre, cmap, LUT_f, T_int, True,  None), hr)
            p_cls   = psnr(filter_frame(pre, cmap, LUT_f, T_int, False, None), hr)
            p_taps  = {b: psnr(filter_frame(pre, cmap,
                                            np.round(LUT_f * (1 << b)).astype(np.int64),
                                            T_int, True, b), hr) for b in bits}
            p_ship  = psnr(filter_frame(pre, cmap,
                                        np.round(LUT_f * 8192).astype(np.int64),
                                        T_int, False, 13), hr)

            rows.append(dict(seq=seq, qp=qp, pre=p_pre, float=p_float,
                             cls=p_cls, shipped=p_ship, taps=p_taps))
            print(f'{seq:30s} qp{qp}  pre={p_pre:6.3f}  float={p_float:6.3f}  '
                  f'cls={p_cls:6.3f}  shipped={p_ship:6.3f}  '
                  f'tap13={p_taps[13]:6.3f}  [{time.time()-t0:5.0f}s]', flush=True)

    np.savez(args.out, rows=np.array(rows, dtype=object),
             bits=np.array(bits), dc=np.array([dc[b] for b in bits]))
    print(f'\nwrote {args.out}  ({len(rows)} runs, {time.time()-t0:.0f}s)')


if __name__ == '__main__':
    main()
