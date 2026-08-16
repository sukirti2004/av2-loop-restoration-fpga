# RDO Filter — FPGA Implementation

Rate-distortion-optimized mode selection between three per-RU (256x256) candidates —
NONE (no filtering), PC, and NS — implemented as a Vivado block design and validated
end-to-end on a PYNQ-Z2 board.

For each restoration unit, the FPGA computes MSE-vs-HR (plus a lambda-weighted rate term)
for all three candidates over four parallel AXI-DMA input streams and selects the winner,
matching a software golden-model reference bit-for-bit.

- `rdo_filter.xpr` / `rdo_filter.srcs/` — Vivado project and RTL sources
- `rdo_filter_bd_wrapper/` — exported bitstream package (`.bit` + `.hwh`) for deployment via PYNQ
- `rdo_notebook.ipynb` — hardware validation notebook: for each of 13 test sequences,
  trains per-RU NS taps, runs the full-frame PC and NS filters on hardware, feeds
  (HR, PRELR, PC-HW, NS-HW) into the RDO IP, and confirms 100% per-RU agreement
  between the FPGA's winner selection and the software MSE-argmin golden

Note: the large `rdo_filter_bd_wrapper.dcp` synthesis checkpoint (~85MB, inside
`rdo_filter.srcs/utils_1/imports/synth_1/`) is intentionally excluded — regenerate it in
Vivado by re-running synthesis on `rdo_filter_bd_wrapper` from the sources above.
