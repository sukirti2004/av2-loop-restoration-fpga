"""Fixed-point Python golden model for the NS (Non-Separable Wiener) filter.

Trains per-restoration-unit (256x256) Wiener taps from a pre-LR / HR frame pair,
then applies them per-RU to reproduce the FPGA's per-pixel output bit-for-bit
on the interior of the frame.

Frame edges (outermost 3 rows and 3 cols) do NOT match hardware bit-for-bit:
the golden pads symmetrically, while the FPGA line buffer wraps into the next
raster row. Callers should clip [3:-3, 3:-3] before comparing.
"""

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view


class NSGolden:
    PATCH_SIZE   = 7
    HALF         = 3
    FILTER_SIZE  = 49
    RU_SIZE      = 256

    def __init__(self):
        # 7x7 symmetric-support mask (Wiener footprint).
        m = np.zeros((7, 7), dtype=bool)
        for r, cs in [(0,[3]), (1,[2,3,4]), (2,[1,2,3,4,5]),
                       (3,[1,2,3,4,5]), (4,[1,2,3,4,5]),
                       (5,[2,3,4]), (6,[3])]:
            m[r, cs] = True
        self.mask = m.ravel()
        self.mi   = np.where(self.mask)[0]
        pos = {int(i): k for k, i in enumerate(self.mi)}

        # Symmetry basis: 11 mirror-pair columns + 1 center singleton = 12.
        seen, cols = set(), []
        for i in self.mi:
            i = int(i)
            if i in seen:
                continue
            j = self.mask.size - 1 - i
            c = np.zeros(self.mi.size, dtype=np.float32)
            c[pos[i]] = 1.0
            if j != i:
                c[pos[j]] = 1.0
            cols.append(c)
            seen.update([i, j])
        self.basis = np.stack(cols, axis=1)
        self.K = self.basis.shape[1]

        # Flat (row-major, 0..48) positions each basis column touches.
        self.pairs = [
            [int(self.mi[r]) for r in np.where(self.basis[:, k] == 1.0)[0]]
            for k in range(self.K)
        ]
        # Number of active taps per basis column (2 for pairs, 1 for center).
        self.w_vec = self.basis.sum(0).astype(np.float64)

    # ------------------------------------------------------------------ train

    def _train_one_ru(self, sr_ru, hr_ru, sr_padded_slab):
        H, S, F, K = self.HALF, self.PATCH_SIZE, self.FILTER_SIZE, self.K

        win     = sliding_window_view(sr_padded_slab, (S, S))
        Xh, Xw  = sr_ru.shape
        patches = win[:Xh, :Xw].reshape(-1, F)
        Xm      = patches[:, self.mask].astype(np.float64) / 255.0
        y       = hr_ru.astype(np.float64).ravel() / 255.0
        XB      = Xm @ self.basis
        A       = XB.T @ XB + 0.01 * np.eye(K)
        b       = XB.T @ y

        KKT = np.zeros((K + 1, K + 1))
        KKT[:K, :K] = A
        KKT[:K, K]  = self.w_vec
        KKT[K, :K]  = self.w_vec
        try:
            f_u = np.linalg.solve(KKT, np.concatenate([b, [1.0]]))[:K]
        except np.linalg.LinAlgError:
            return np.array([0]*11 + [32], dtype=np.int8), 2048

        f_c   = self.basis @ f_u
        yy    = float(y @ y)
        N     = len(y)
        A_K   = XB.T @ XB
        b_K   = XB.T @ y
        rep   = np.array([int(np.argmax(self.basis[:, k])) for k in range(K)])
        f_uc  = f_c[rep].astype(np.float64)
        scale = 63 / max(abs(f_uc).max(), 1e-12)
        f_int = np.clip(np.round(f_uc * scale), -63, 63).astype(np.int64)

        def mse(fi):
            fr = fi / scale
            s  = float(self.w_vec @ fr)
            if abs(s) < 1e-6:
                return float('inf')
            fs = fr / s
            return float((yy - 2 * fs @ b_K + fs @ A_K @ fs) / N)

        best = mse(f_int)
        for _ in range(20):
            improved = False
            for k in range(K):
                best_delta = 0
                for d in (-1, 1):
                    t = f_int.copy()
                    t[k] = np.clip(t[k] + d, -63, 63)
                    if t[k] == f_int[k]:
                        continue
                    m = mse(t)
                    if m < best - 1e-12:
                        best, best_delta = m, d
                if best_delta:
                    f_int[k] = np.clip(f_int[k] + best_delta, -63, 63)
                    improved = True
            if not improved:
                break

        ws   = int(2 * f_int[:11].sum() + f_int[11])
        norm = int(round(65536 / ws)) & 0xFFFF if ws != 0 else 0
        return f_int.astype(np.int8), norm

    def train(self, prelr, hr):
        """Train per-RU Wiener taps for one frame.

        Returns (all_taps, all_norms) indexed by bank = ru_row * 8 + ru_col
        (matches the RTL tap_reg_file addressing).
        """
        Ht, Wt   = prelr.shape
        RU_ROWS  = (Ht + self.RU_SIZE - 1) // self.RU_SIZE
        RU_COLS  = (Wt + self.RU_SIZE - 1) // self.RU_SIZE
        HALF     = self.HALF
        sr_pad   = np.pad(prelr, HALF, mode="symmetric")
        max_bank = (RU_ROWS - 1) * 8 + (RU_COLS - 1) + 1
        all_taps  = [np.zeros(12, dtype=np.int8) for _ in range(max_bank)]
        all_norms = [0 for _ in range(max_bank)]
        for r in range(RU_ROWS):
            r0, r1 = r * self.RU_SIZE, min((r + 1) * self.RU_SIZE, Ht)
            for c in range(RU_COLS):
                c0, c1 = c * self.RU_SIZE, min((c + 1) * self.RU_SIZE, Wt)
                bank = r * 8 + c
                slab = sr_pad[r0:r1 + 2 * HALF, c0:c1 + 2 * HALF]
                f_int, norm = self._train_one_ru(
                    prelr[r0:r1, c0:c1], hr[r0:r1, c0:c1], slab)
                all_taps[bank]  = f_int
                all_norms[bank] = norm
        return all_taps, all_norms

    # ------------------------------------------------------------------ apply

    def apply(self, prelr, all_taps, all_norms):
        """Apply trained per-RU taps to a frame. Returns full-frame filtered image
        (uint8, same shape as prelr). Uses symmetric padding at frame edges."""
        Ht, Wt  = prelr.shape
        RU_ROWS = (Ht + self.RU_SIZE - 1) // self.RU_SIZE
        RU_COLS = (Wt + self.RU_SIZE - 1) // self.RU_SIZE
        HALF    = self.HALF
        src     = np.pad(prelr, HALF, mode="symmetric").astype(np.int32)
        out     = np.zeros((Ht, Wt), dtype=np.uint8)

        for r in range(RU_ROWS):
            r0, r1 = r * self.RU_SIZE, min((r + 1) * self.RU_SIZE, Ht)
            for c in range(RU_COLS):
                c0, c1 = c * self.RU_SIZE, min((c + 1) * self.RU_SIZE, Wt)
                bank = r * 8 + c
                taps = all_taps[bank]
                norm = all_norms[bank]
                acc = np.zeros((r1 - r0, c1 - c0), dtype=np.int64)
                for k, positions in enumerate(self.pairs):
                    ps = np.zeros((r1 - r0, c1 - c0), dtype=np.int32)
                    for p in positions:
                        dr, dc = p // 7 - HALF, p % 7 - HALF
                        ps += src[HALF + r0 + dr:HALF + r1 + dr,
                                  HALF + c0 + dc:HALF + c1 + dc]
                    acc += int(taps[k]) * ps
                out[r0:r1, c0:c1] = np.clip(
                    (acc * int(norm) + (1 << 15)) >> 16, 0, 255
                ).astype(np.uint8)
        return out
