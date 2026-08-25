# NS Filter — FPGA Implementation

Non-separable Wiener filter for AV2 loop restoration. 12 symmetric taps, per-RU trained,
run as a custom AXI IP on the PL side of a PYNQ-Z2 (Zynq-7020). See the
[top-level README](../README.md) for how this module fits into the wider pipeline.

## What it does

For each 256×256 restoration unit (RU) the host loads a set of quantized taps into the
IP's tap register file and streams pre-LR pixels through it via DMA. The IP applies the
Wiener filter with per-RU tap swapping at RU boundaries and streams the restored pixels
back. A software golden model (`ns_golden.py`) computes the same fixed-point result and
the notebook confirms hardware output pixel-exact against it.

## AXI register map (`ns_filter_1_0`)

| Offset      | Field                          | Notes                                                   |
|-------------|--------------------------------|---------------------------------------------------------|
| `0x00–0x2C` | 12 tap coefficients            | Q-format matched to `ns_golden.py`                      |
| `0x30`      | Normalization / bias           | fixed per configuration                                 |
| `0x34`      | Image width  (TLAST cosmetic)  | current bitstream is width-parameterized in RTL         |
| `0x38`      | Image height                   | (see limitation below)                                  |
| `0x3C`      | Control — bit0 START, bit1 FLIP, bits\[15:8\] bank select | pulse START after DMA arm |

**Limitation:** the checked-in bitstream is compiled for FRAME_W = 1920. The Aug-15 RTL
rewrite ([`control.v`](fpga_ns.srcs/sources_1/new/control.v)) parameterized the row-swap
pipeline so other widths only need a re-synthesis, not an RTL edit
(`MAX_ROW_DELAY = 3*MAX_W + 6`, runtime-sized).

## Layout

| Path                                  | Contents                                                     |
|---------------------------------------|--------------------------------------------------------------|
| `fpga_ns.xpr`, `fpga_ns.srcs/`        | Vivado 2025.2 project + RTL sources                          |
| `../ip_repo/ns_filter_1_0/`           | Packaged AXI IP referenced by the block design               |
| `ns_filter_bd_wrapper/`               | Exported `.bit` + `.hwh` for PYNQ (no Vivado needed on board) |
| `ns_notebook.ipynb`                   | Hardware validation notebook                                  |
| `ns_golden.py`                        | Fixed-point Python reference model, bit-exact with RTL       |
| `hw_run_ns.py`                        | End-to-end script variant of the notebook                    |
| `gen_ns_vectors.py`, `gen_multi_ru_vectors*.py` | Simulation test-vector generators                  |
| `tb_multi_ru_verify.v`                | Multi-RU boundary testbench (vertical + 2×/3× horizontal)    |
| `*.hex`                               | Generated test vectors (taps / input / expected)             |

## Results

Interior exact-match = **100.0000 %** on all 13 sequences after the Aug-15 ROW_DELAY fix
(row-swap timing correction, [committed](../../..) as `cab8645`). Flat also improves to
~99.83 % on average (~0.17 % right-edge wrap remains by design). Notebook prints per-RU
and per-frame agreement plus mean interior MAE.

## Quick start

Copy `ns_filter_bd_wrapper/` (both `.bit` and `.hwh`) to the PYNQ-Z2 alongside
`ns_notebook.ipynb`, open the notebook, run all cells. To re-synthesize the bitstream,
open `fpga_ns.xpr` in Vivado 2025.2 and run through implementation and
`write_bitstream`. Test-vector generators run off-board with plain Python + numpy.
