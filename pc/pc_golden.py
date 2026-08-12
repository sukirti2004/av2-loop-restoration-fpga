"""
pc_golden.py — Bit-exact software reference model for the PC filter RTL.

Every arithmetic operation here mirrors the Verilog exactly: same integer
widths, same truncation points, same rounding. Output is expected to match
the FPGA on 100% of pixels.

RTL correspondence
------------------
  feature_compute.v   integer Laplacians on raw uint8, 25-term sum,
                      (sum * 21049 + 4096) >> 13  -> Q2.14 feature
  quantizer_ctx.v     count of (feat >= t_i) per direction, packed
                      ctx = {lv3, lv2, lv1, lv0}
  cluster_lut.v       ctx -> filter_id
  filter_lut.v        filter_id -> 49 taps (Q3.13)
  mac_engine.v        sum(tap * px), then (sum + 4096) >> 13, clip [0,255]

Note on patch orientation
-------------------------
line_buffer.v presents the patch 180-degree rotated: pixels_flat[r*7+c]
= P[R-r][C-c]. This model uses natural orientation, which is equivalent
because:
  * the directional Laplacian features are invariant under 180 rotation
    (lap = -a + 2c - b is symmetric in a and b), and
  * the filter taps are origin-symmetric, tap[k] == tap[48-k].
`check_tap_symmetry()` verifies the second condition at load time.

Usage
-----
    from pc_golden import PCGolden

    g = PCGolden('pc_qp_group_1.npz')
    out = g.filter_image(img)              # vectorised, whole frame
    px, ctx, fid = g.filter_pixel(patch)   # single 7x7 patch, for debugging
"""

import numpy as np

# ── RTL constants ────────────────────────────────────────────────────────────
FEAT_SCALE = 21049      # feature_compute.v: sum * 21049
FEAT_SHIFT = 13         # feature_compute.v: [28:13]
FEAT_ROUND = 4096       # feature_compute.v: + 30'd4096
TAP_SHIFT  = 13         # mac_engine.v:      >>> 13
TAP_ROUND  = 4096       # mac_engine.v:      + 30'sd4096
TAP_SCALE  = 8192       # Q3.13
THR_SCALE  = 16384      # Q2.14


class PCGolden:
    """Bit-exact reference model for the PC filter."""

    def __init__(self, npz_path, hex_path=None):
        data = np.load(npz_path)
        self.T_float     = data['T']
        self.LUT         = data['LUT']
        self.cluster_map = data['cluster_map'].astype(np.int32)

        # Q3.13 integer taps. If the .hex actually loaded into BRAM is
        # available, prefer it — that removes any chance of the model and
        # the hardware drifting apart through separate quantisation.
        if hex_path is not None:
            self.LUT_fixed = self._load_hex(hex_path)
        else:
            self.LUT_fixed = np.round(self.LUT * TAP_SCALE).astype(np.int32)

        # Q2.14 thresholds, exactly as written to the AXI-Lite registers
        self.T_int = np.round(self.T_float * THR_SCALE).astype(np.int32)

        self.check_tap_symmetry()

    # ── Loading ──────────────────────────────────────────────────────────────
    @staticmethod
    def _load_hex(path, n_filters=256, n_taps=49):
        """Parse filter_lut.hex — one line per filter, taps packed MSB-first."""
        with open(path) as f:
            lines = [l.strip() for l in f if l.strip()]
        taps = np.zeros((n_filters, n_taps), dtype=np.int32)
        for i, line in enumerate(lines[:n_filters]):
            for k in range(n_taps):
                nib = line[(n_taps - 1 - k) * 4:(n_taps - 1 - k) * 4 + 4]
                v = int(nib, 16)
                taps[i, k] = v - 65536 if v >= 32768 else v
        return taps

    def check_tap_symmetry(self):
        """Origin symmetry is what makes the 180-degree patch rotation a no-op."""
        sym = np.all(self.LUT_fixed == self.LUT_fixed[:, ::-1], axis=1)
        if not sym.all():
            raise ValueError(
                f"{(~sym).sum()} filters are not origin-symmetric. "
                "The 180-degree patch rotation in line_buffer.v is NOT a no-op "
                "for these, and this model will disagree with the RTL."
            )
        return True

    # ── Single patch (reference implementation, mirrors RTL line by line) ────
    def filter_pixel(self, patch):
        """
        patch : (7,7) uint8, centre at patch[3,3]
        returns (pixel_out, ctx, filter_id)
        """
        p = patch.astype(np.int32)

        # feature_compute.v STAGE 1 — integer Laplacians over the 5x5 interior
        sums = [0, 0, 0, 0]
        for gr in range(1, 6):
            for gc in range(1, 6):
                c2 = 2 * p[gr, gc]
                sums[0] += abs(-p[gr,   gc-1] + c2 - p[gr,   gc+1])  # H
                sums[1] += abs(-p[gr-1, gc  ] + c2 - p[gr+1, gc  ])  # V
                sums[2] += abs(-p[gr-1, gc-1] + c2 - p[gr+1, gc+1])  # D
                sums[3] += abs(-p[gr-1, gc+1] + c2 - p[gr+1, gc-1])  # A

        # feature_compute.v STAGE 3 — scale to Q2.14 with round-to-nearest
        feats = [((int(s) * FEAT_SCALE + FEAT_ROUND) >> FEAT_SHIFT) & 0xFFFF
                 for s in sums]

        # quantizer_ctx.v — count thresholds met, pack {lv3,lv2,lv1,lv0}
        lv  = [int((f >= self.T_int).sum()) for f in feats]
        ctx = lv[0] | (lv[1] << 3) | (lv[2] << 6) | (lv[3] << 9)

        # cluster_lut.v -> filter_lut.v
        fid  = int(self.cluster_map[ctx])
        taps = self.LUT_fixed[fid]

        # mac_engine.v — MAC, round-to-nearest shift, saturating clip
        acc = int(np.dot(taps, p.flatten()))
        px  = int(np.clip((acc + TAP_ROUND) >> TAP_SHIFT, 0, 255))

        return px, ctx, fid

    # ── Whole image (vectorised, identical arithmetic) ───────────────────────
    def filter_image(self, img, block_rows=256):
        """
        img : (H,W) uint8
        returns (H,W) uint8 — interior filtered, 3-pixel border copied from input,
        matching what the FPGA + PS reconstruction produces.
        """
        H, W = img.shape
        if H < 7 or W < 7:
            raise ValueError("image must be at least 7x7")

        out = img.copy()
        a = img.astype(np.int32)

        # Process in row blocks to bound peak memory on the PYNQ's 512 MB.
        for r0 in range(3, H - 3, block_rows):
            r1 = min(r0 + block_rows, H - 3)
            out[r0:r1, 3:W-3] = self._filter_block(a, r0, r1, W)
        return out

    def _filter_block(self, a, r0, r1, W):
        """Filter centre rows [r0, r1), columns [3, W-3)."""
        def S(dy, dx):
            """Neighbour plane: a[i+dy, j+dx] for centres i in [r0,r1), j in [3,W-3)."""
            return a[r0+dy : r1+dy, 3+dx : W-3+dx]

        # ── Features: 25-term sum of |Laplacian| per direction ───────────────
        shape = (r1 - r0, W - 6)
        sums  = [np.zeros(shape, dtype=np.int32) for _ in range(4)]

        for dy in range(-2, 3):
            for dx in range(-2, 3):
                c2 = 2 * S(dy, dx)
                sums[0] += np.abs(-S(dy,   dx-1) + c2 - S(dy,   dx+1))
                sums[1] += np.abs(-S(dy-1, dx  ) + c2 - S(dy+1, dx  ))
                sums[2] += np.abs(-S(dy-1, dx-1) + c2 - S(dy+1, dx+1))
                sums[3] += np.abs(-S(dy-1, dx+1) + c2 - S(dy+1, dx-1))

        # Q2.14 with round-to-nearest, masked to 16 bits as the RTL slice does
        feats = [((s * FEAT_SCALE + FEAT_ROUND) >> FEAT_SHIFT) & 0xFFFF
                 for s in sums]

        # ── Quantise and pack context ────────────────────────────────────────
        ctx = np.zeros(shape, dtype=np.int32)
        for d, f in enumerate(feats):
            lv = np.zeros(shape, dtype=np.int32)
            for t in self.T_int:
                lv += (f >= t)
            ctx |= lv << (3 * d)

        fid = self.cluster_map[ctx]

        # ── MAC: accumulate tap-by-tap to avoid a (H,W,49) array ─────────────
        acc = np.zeros(shape, dtype=np.int64)
        for k in range(49):
            r, c = divmod(k, 7)
            acc += self.LUT_fixed[fid, k].astype(np.int64) * S(r - 3, c - 3)

        return np.clip((acc + TAP_ROUND) >> TAP_SHIFT, 0, 255).astype(np.uint8)


# ── Self-test ────────────────────────────────────────────────────────────────
if __name__ == '__main__':
    import sys

    npz = sys.argv[1] if len(sys.argv) > 1 else 'pc_qp_group_1.npz'
    g = PCGolden(npz)
    print(f"Loaded {npz}")
    print(f"  thresholds (Q2.14): {g.T_int.tolist()}")
    print(f"  tap symmetry      : OK")

    # Random image — checks the vectorised path against the per-patch reference
    rng = np.random.default_rng(0)
    img = rng.integers(0, 256, size=(64, 64), dtype=np.uint8)

    fast = g.filter_image(img)

    mismatches = 0
    for i in range(3, 61):
        for j in range(3, 61):
            ref, _, _ = g.filter_pixel(img[i-3:i+4, j-3:j+4])
            if ref != fast[i, j]:
                mismatches += 1
                if mismatches <= 5:
                    print(f"  MISMATCH ({i},{j}): patch={ref} vectorised={fast[i,j]}")

    total = 58 * 58
    print(f"\nVectorised vs per-patch: {total - mismatches}/{total} exact "
          f"({100*(total-mismatches)/total:.2f}%)")
    print("PASS" if mismatches == 0 else f"FAIL — {mismatches} mismatches")
