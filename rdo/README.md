# RDO Filter — FPGA Implementation

Rate-distortion-optimized mode selection between three per-RU (256x256) candidates —
NONE (no filtering), PC, and NS — implemented as a Vivado block design and validated
end-to-end on a PYNQ-Z2 board.

For each restoration unit, the FPGA computes MSE-vs-HR (plus a lambda-weighted rate term)
for all three candidates over four parallel AXI-DMA input streams and selects the winner,
matching a software golden-model reference bit-for-bit.

- `rdo_filter.xpr` / `rdo_filter.srcs/` — Vivado project and RTL sources
- `rdo_filter_bd_wrapper/` — exported bitstream package (`.bit` + `.hwh`) for deployment via PYNQ
- `rdo_notebook.ipynb`, `rdo_notebook_test4.ipynb` — hardware validation notebooks: dispatch
  HR/NONE/PC/NS tiles over DMA, compare the FPGA's per-RU winner selection against a software
  MSE-argmin reference across multiple frames/QPs

Note: the large `rdo_filter_bd_wrapper.dcp` synthesis checkpoint (~85MB, inside
`rdo_filter.srcs/utils_1/imports/synth_1/`) is intentionally excluded — regenerate it in
Vivado by re-running synthesis on `rdo_filter_bd_wrapper` from the sources above.
