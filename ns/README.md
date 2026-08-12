# NS Filter — FPGA Implementation

Non-Separable Wiener filter, implemented as a Vivado block design and validated end-to-end
on a PYNQ-Z2 board.

- `fpga_ns.xpr` / `fpga_ns.srcs/` — Vivado project and RTL sources
- `ns_filter_bd_wrapper/` — exported bitstream package (`.bit` + `.hwh`) for deployment via PYNQ
- `hw_run_ns.py` — end-to-end hardware validation: loads a frame, computes quantized taps,
  streams it through the FPGA via DMA, and compares against a Python fixed-point golden model
  (PSNR vs. ground truth)
- `gen_ns_vectors.py`, `gen_multi_ru_vectors*.py`, `gen_ru_boundary_vectors.py` — test vector
  generators for simulation
- `tb_multi_ru_verify.v` — testbench
- `*.hex` — generated test vectors (taps / input / expected output)
- `ns_notebook.ipynb`, `test.ipynb`, `test_hw.ipynb` — notebooks used for hardware runs and
  verification
