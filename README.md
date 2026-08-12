# AV2 Loop Restoration Filters — FPGA Implementation

FPGA (Xilinx PYNQ-Z2) implementations of two AV2 in-loop restoration filters:

- [`ns/`](ns/) — Non-Separable (NS) Wiener filter
- [`pc/`](pc/) — Pixel Classification (PC) filter

A third module, combining both via RDO (rate-distortion-optimized mode selection), is in
progress and will be added as `rdo/` once ready.

Each subdirectory is a self-contained Vivado project (`.xpr` + `.srcs`), plus Python scripts
used to generate test vectors, Jupyter notebooks used to drive PYNQ hardware runs, and the
exported bitstream package (`.bit`/`.hwh`) for deployment.

## Structure

Vivado's generated build directories (`.cache`, `.gen`, `.hw`, `.ip_user_files`, `.runs`,
`.sim`, `.tmp`) are excluded via `.gitignore` — they regenerate automatically when the project
is reopened in Vivado. Only authored sources are versioned.

## Requirements

- Vivado 2025.2 (or compatible)
- PYNQ-Z2 board for hardware runs (`pynq` Python package for the notebooks)
