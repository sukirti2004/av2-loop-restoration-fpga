# PC Filter — FPGA Implementation

Pixel Classification filter, implemented as a Vivado block design and validated end-to-end
on a PYNQ-Z2 board.

See [`PC_Filter_Hardware_Summary.md`](PC_Filter_Hardware_Summary.md) and
[`PC_Filter_PSNR_Results.md`](PC_Filter_PSNR_Results.md) for the hardware architecture and
measured results.

- `fpga_pc.xpr` / `fpga_pc.srcs/` — Vivado project and RTL sources
- `pc_filter_bd_wrapper/` — exported bitstream package (`.bit` + `.hwh`) for deployment via PYNQ
- `filter_lut.hex`, `cluster_map.hex` — LUT / cluster map data (`older_hex/` holds a prior
  version kept for reference)
- `pc_notebook.ipynb`, `test.ipynb` — notebooks used for hardware runs and verification
