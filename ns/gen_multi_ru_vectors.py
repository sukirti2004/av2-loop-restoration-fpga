import numpy as np

# ---------- CONFIG ----------
# VERTICAL regression: 2 RUs stacked, boundary at row 256. Swap H,W and swap
# the tap-set keys ((0,0) top RU, (1,0) bottom RU) to match the vertical geometry.
H, W = 512, 256
RU_SIZE = 256
OUT_FILE = "ns_multi_ru"

TAPS = {
    (0,0): [-2]*11 + [50],      # sharpener  (top RU)      DC gain = 6
    (1,0): [ 5]*12,             # blur       (bottom RU)   DC gain = 115
}
def dc_gain(t):  return 2*sum(t[:11]) + t[11]
NORMS = { ru: int(round((1.0/dc_gain(t)) * (1<<16))) for ru, t in TAPS.items() }
assert NORMS[(0,0)] == 10923, NORMS
assert NORMS[(1,0)] == 570,   NORMS

# ---------- SUPPORT ----------
# 23-cell diamond, indexed [dr+3][dc+3]
DIAMOND = np.array([
    [0,0,0,1,0,0,0],
    [0,0,1,1,1,0,0],
    [0,1,1,1,1,1,0],
    [1,1,1,1,1,1,1],
    [0,1,1,1,1,1,0],
    [0,0,1,1,1,0,0],
    [0,0,0,1,0,0,0],
], dtype=np.int32)

# 11 origin-symmetric pairs + center.
# Replace the derived PAIR_POSITIONS block with the exact RTL order:
PAIR_POSITIONS = [
    (-3, 0), (-2,-1), (-2, 0), (-2, 1),
    (-1,-2), (-1,-1), (-1, 0), (-1, 1), (-1, 2),
    ( 0,-2), ( 0,-1),
]
assert len(PAIR_POSITIONS) == 11

def mirror(coord, size):
    if coord < 0: return -coord
    if coord >= size: return 2*size - 2 - coord
    return coord

def apply_pixel(img, r, c, taps):
    """taps[0..10] = pair coeffs, taps[11] = center coeff.
       Returns int20 pre-normalize sum."""
    total = 0
    for i, (dr, dc) in enumerate(PAIR_POSITIONS):
        r1, c1 = mirror(r+dr, H), mirror(c+dc, W)
        r2, c2 = mirror(r-dr, H), mirror(c-dc, W)
        total += (int(img[r1,c1]) + int(img[r2,c2])) * taps[i]
    total += int(img[r, c]) * taps[11]
    return total

def normalize_saturate(x, norm):
    prod = x * norm            # int37-ish
    rounded = (prod + (1<<15)) >> 16
    if rounded < 0:   return 0
    if rounded > 255: return 255
    return rounded

# ---------- INPUT: varying data so mistakes actually surface ----------
rng = np.random.default_rng(0xC0FFEE)
img = np.zeros((H, W), dtype=np.uint8)
# gradient background + random speckle + a hot stripe crossing both RU columns
for r in range(H):
    for c in range(W):
        img[r,c] = (r + c) & 0xFF
img ^= rng.integers(0, 32, size=(H,W), dtype=np.uint8)

# --------------------------------------------------------------------
# BUG-EXPOSING PATTERN around the RU-row boundary at row 256.
#
# The ORIGINAL vector had `img[254:258, :] = 200` — a uniform 200-pixel
# band straddling the boundary. Because both RU tap sets have DC gain = 1
# by construction (norm chosen to make weighted_sum -> 1.0), a uniform
# window produces the SAME output value for either RU's taps, so the
# RU-row tap-swap timing bug was invisible in this TB.
#
# Replace with an explicitly varying diagonal pattern in rows 250..261
# (covers all pixels that ANY 7x7 window centered on rows 253..258
# might see). This guarantees numerically different outputs for the
# sharpener [-2]*11+[50] vs the blur [5]*12 taps, so if HW loads the
# wrong RU's taps for any center pixel in rows 253..258, the compare
# will report a mismatch.
# --------------------------------------------------------------------
rr, cc = np.mgrid[250:262, 0:W]                          # 12 rows, W cols
img[250:262, :] = ((rr * 89 + cc * 47) & 0xFF).astype(np.uint8)
img[250:262, :] ^= rng.integers(0, 64, size=(12, W), dtype=np.uint8)

# ---------- GOLDEN: interior only (borders handled in PS Python) ----------
# Full HxW array so raster indices align with input; borders left as 0xFF sentinel.
# Compare loop in TB must SKIP the 3-pixel border on all sides.
out = np.full((H, W), 0xFF, dtype=np.uint8)
for r in range(3, H-3):
    for c in range(3, W-3):
        ru = (r // RU_SIZE, c // RU_SIZE)
        taps = TAPS[ru]
        s = apply_pixel(img, r, c, taps)
        out[r,c] = normalize_saturate(s, NORMS[ru])

# ---------- EMIT HEX ----------
with open(f"{OUT_FILE}_input.hex","w") as f:
    for v in img.flatten(): f.write(f"{v:02x}\n")
with open(f"{OUT_FILE}_expected.hex","w") as f:
    for v in out.flatten(): f.write(f"{v:02x}\n")

# Taps file: 14 bytes per RU = 12 tap-bytes + norm hi-byte + norm lo-byte.
# Order: first RU loaded to live via SOF swap; second RU loaded to shadow mid-frame.
with open(f"{OUT_FILE}_taps.hex","w") as f:
    for ru in [(0,0),(1,0)]:
        for t in TAPS[ru]:
            f.write(f"{t & 0x7F:02x}\n")
        n = NORMS[ru]
        f.write(f"{(n >> 8) & 0xFF:02x}\n")
        f.write(f"{n & 0xFF:02x}\n")

print("wrote", OUT_FILE, "input/expected/taps hex files")
print("RU norms:", NORMS)