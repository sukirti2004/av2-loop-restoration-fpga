
"""
gen_ru_boundary_vectors.py

Generate test vectors for verifying RU boundary tap swapping.
Assumes:
 - Frame: 256x512 (2 vertical RUs)
 - RU size: 256 rows
 - Trailing 7x7 window (matches RTL)
"""

import numpy as np

FRAME_W = 256
FRAME_H = 512
RU_SIZE = 256

mirror_pairs = [
    (3,45),(9,39),(10,38),(11,37),
    (15,33),(16,32),(17,31),(18,30),
    (19,29),(22,26),(23,25),
]
center_idx = 24

# Two validated tap sets
taps_ru0 = [-2]*11 + [50]
norm_ru0 = 10923

taps_ru1 = [5]*12
norm_ru1 = 570


def rtl_apply_pixel(window_flat, taps, norm):
    pair_sums = [int(window_flat[a]) + int(window_flat[b])
                 for a,b in mirror_pairs]
    pair_sums.append(int(window_flat[center_idx]))

    products = [ps*t for ps,t in zip(pair_sums,taps)]
    raw_sum = sum(products)

    mult = raw_sum * norm
    rounded = mult + (1<<15)
    shifted = rounded >> 16

    if shifted < 0:
        return 0
    if shifted > 255:
        return 255
    return shifted


img = np.fromfunction(
    lambda r,c: ((37*r + 19*c) & 0xFF),
    (FRAME_H,FRAME_W),
    dtype=int
).astype(np.uint8)

expected = np.zeros_like(img)

for r in range(6, FRAME_H):
    for c in range(6, FRAME_W):

        window = img[r-6:r+1, c-6:c+1].flatten()

        if r < RU_SIZE:
            taps = taps_ru0
            norm = norm_ru0
        else:
            taps = taps_ru1
            norm = norm_ru1

        expected[r,c] = rtl_apply_pixel(window,taps,norm)

with open("ru_input.hex","w") as f:
    for v in img.flat:
        f.write(f"{int(v):02x}\n")

with open("ru_expected.hex","w") as f:
    for v in expected.flat:
        f.write(f"{int(v):02x}\n")

with open("ru0_taps.hex","w") as f:
    for t in taps_ru0:
        f.write(f"{t & 0x7F:02x}\n")

with open("ru1_taps.hex","w") as f:
    for t in taps_ru1:
        f.write(f"{t & 0x7F:02x}\n")

with open("ru0_norm.hex","w") as f:
    f.write(f"{norm_ru0:04x}\n")

with open("ru1_norm.hex","w") as f:
    f.write(f"{norm_ru1:04x}\n")

print("Generated:")
print("  ru_input.hex")
print("  ru_expected.hex")
print("  ru0_taps.hex")
print("  ru1_taps.hex")
print("  ru0_norm.hex")
print("  ru1_norm.hex")
