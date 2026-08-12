import numpy as np

# ---------- CONFIG ----------
# 3-RU-COLUMN test: boundaries at col 256 and col 512, both away from the
# frame edge (unlike the 2-RU horizontal test, where the row-wrap col_event
# at col 0/511 is masked by the interior border exclusion). This is the only
# way to validate col_event firing at a boundary OTHER than the one specific
# position (col 256) the 2-RU test exercises.
H, W = 256, 768
RU_SIZE = 256
OUT_FILE = "ns_multi_ru_h3"

TAPS = {
    (0,0): [-2]*11 + [50],      # sharpener        DC gain = 6
    (0,1): [ 5]*12,             # blur             DC gain = 115
    (0,2): [ 3]*11 + [10],      # mild blur/edge   DC gain = 76
}
def dc_gain(t):  return 2*sum(t[:11]) + t[11]
NORMS = { ru: int(round((1.0/dc_gain(t)) * (1<<16))) for ru, t in TAPS.items() }
assert NORMS[(0,0)] == 10923, NORMS
assert NORMS[(0,1)] == 570,   NORMS
assert NORMS[(0,2)] == 862,   NORMS

# ---------- SUPPORT ----------
# 11 origin-symmetric pairs + center, exact RTL order.
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

# ---------- INPUT: varying data, with bands straddling BOTH boundaries ----------
rng = np.random.default_rng(0xC0FFEE)
img = np.zeros((H, W), dtype=np.uint8)
for r in range(H):
    for c in range(W):
        img[r,c] = (r + c) & 0xFF
img ^= rng.integers(0, 32, size=(H,W), dtype=np.uint8)
img[:, 254:258] = 200   # band straddling RU-col boundary at 256
img[:, 510:514] = 100   # band straddling RU-col boundary at 512

# ---------- GOLDEN: interior only (borders handled in PS Python) ----------
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
# Order: RU(0,0) first (loaded to live via SOF swap), then (0,1), then (0,2).
with open(f"{OUT_FILE}_taps.hex","w") as f:
    for ru in [(0,0),(0,1),(0,2)]:
        for t in TAPS[ru]:
            f.write(f"{t & 0x7F:02x}\n")
        n = NORMS[ru]
        f.write(f"{(n >> 8) & 0xFF:02x}\n")
        f.write(f"{n & 0xFF:02x}\n")

print("wrote", OUT_FILE, "input/expected/taps hex files")
print("RU norms:", NORMS)
