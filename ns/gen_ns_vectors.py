"""
gen_ns_vectors.py — generate hex test vectors for the NS filter RTL.

Set TEST_CASE and re-run. Testbench (tb_ns_verify.v) is unchanged.
"""
import numpy as np

TEST_CASE = "saturate_low"   # "identity" | "blur" | "sharpen" | "saturate_high" | "saturate_low"

H, W = 12, 8

# ----- test configurations -----------------------------------------------
if TEST_CASE == "identity":
    taps, norm, input_val = [0]*11 + [63], 1040, 128
elif TEST_CASE == "blur":
    # All 12 taps equal — every lane must carry data (not just the center)
    taps, norm, input_val = [5]*12,        570,   128
elif TEST_CASE == "sharpen":
    # Negative pair taps + positive center — exercises signed multiplies
    taps, norm, input_val = [-2]*11 + [50], 10923, 128
elif TEST_CASE == "saturate_high":
    # Deliberately over-strong gain — must clip at 255
    taps, norm, input_val = [63]*12,        100,   128
elif TEST_CASE == "saturate_low":
    # All-negative taps with positive input — must clip at 0
    taps, norm, input_val = [-3]*12,        1000,  128
else:
    raise ValueError(f"unknown TEST_CASE: {TEST_CASE}")

# ----- mirror pair map (11 pairs + center) -------------------------------
mirror_pairs = [
    (3, 45), (9, 39), (10, 38), (11, 37),
    (15, 33), (16, 32), (17, 31), (18, 30), (19, 29),
    (22, 26), (23, 25),
]
center_idx = 24

# ----- bit-exact RTL model -----------------------------------------------
def rtl_apply_pixel(window_flat, taps, norm):
    pair_sums = [int(window_flat[a]) + int(window_flat[b]) for a, b in mirror_pairs]
    pair_sums.append(int(window_flat[center_idx]))
    products  = [ps * t for ps, t in zip(pair_sums, taps)]
    raw_sum   = sum(products)
    mult      = raw_sum * norm
    rounded   = mult + (1 << 15)
    shifted   = rounded >> 16
    return 0 if shifted < 0 else (255 if shifted > 255 else shifted)

# For constant input, every window is identical → every output identical.
one_output = rtl_apply_pixel([input_val]*49, taps, norm)

img      = np.full((H, W), input_val, dtype=np.uint8)
expected = np.full((H, W), one_output, dtype=np.uint8)

# ----- write hex files ---------------------------------------------------
with open("ns_input.hex", "w") as f:
    for v in img.flat: f.write(f"{v:02x}\n")
with open("ns_taps.hex", "w") as f:
    for t in taps:     f.write(f"{t & 0x7F:02x}\n")
with open("ns_norm.hex", "w") as f:
    f.write(f"{norm:04x}\n")
with open("ns_expected.hex", "w") as f:
    for v in expected.flat: f.write(f"{v:02x}\n")

print(f"TEST_CASE     = {TEST_CASE}")
print(f"taps          = {taps}")
print(f"norm          = {norm}")
print(f"input pixel   = {input_val}")
print(f"expected out  = {one_output}")