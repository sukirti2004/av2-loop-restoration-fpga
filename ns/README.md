# NS Filter — FPGA Implementation

Non-Separable Wiener filter, implemented as a Vivado block design and validated end-to-end
on a PYNQ-Z2 board.

- `fpga_ns.xpr` / `fpga_ns.srcs/` — Vivado project and RTL sources. The custom AXI IP cores
  referenced by the block design (`pc_axi_1_0`, `ns_filter_1_0`) live in `../ip_repo/`.
- `ns_filter_bd_wrapper/` — exported bitstream package (`.bit` + `.hwh`) for deployment via PYNQ
- `hw_run_ns.py` — end-to-end hardware validation: loads a frame, computes quantized taps,
  streams it through the FPGA via DMA, and compares against a Python fixed-point golden model
  (PSNR vs. ground truth)
- `gen_ns_vectors.py`, `gen_multi_ru_vectors.py`, `gen_multi_ru_vectors_h3.py` — test vector
  generators for simulation
- `tb_multi_ru_verify.v`, `tb_multi_ru_verify_h.v`, `tb_multi_ru_verify_h3.v` — testbenches
  covering distinct RU-boundary geometries (vertical, 2-RU horizontal, 3-RU horizontal),
  under `fpga_ns.srcs/sim_1/`
- `*.hex` — generated test vectors (taps / input / expected output)
- `ns_notebook.ipynb` — notebook used for hardware runs and verification
