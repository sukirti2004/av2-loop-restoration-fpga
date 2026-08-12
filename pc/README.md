# PC Filter — FPGA Implementation

Pixel Classification filter, implemented as a Vivado block design and validated end-to-end
on a PYNQ-Z2 board.

- `fpga_pc.xpr` / `fpga_pc.srcs/` — Vivado project and RTL sources, including `tb_pc_stream.v`
  (streaming-level testbench for the PC filter core, under `fpga_pc.srcs/sim_1/`). The custom
  AXI IP core referenced by the block design (`pc_axi_1_0`) lives in `../ip_repo/`.
- `pc_filter_bd_wrapper/` — exported bitstream package (`.bit` + `.hwh`) for deployment via PYNQ
- `filter_lut.hex`, `cluster_map.hex` — LUT / cluster map data
- `pc_golden.py` — Python reference model of the PC filter (fixed-point, matches the RTL
  bit-for-bit); used by `pc_notebook.ipynb` to verify hardware output against software
- `pc_notebook.ipynb` — hardware validation notebook: runs every uploaded test sequence
  through the FPGA and checks its output against `pc_golden.py`, pixel-exact
