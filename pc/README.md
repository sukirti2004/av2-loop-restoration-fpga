# PC Filter — FPGA Implementation

Pixel Classification filter for AV2 loop restoration. 8-level-per-feature context
classifier + per-class LUT-driven 7x7 filter, run as a custom AXI IP on the PL side of a PYNQ-Z2 (Zynq-7020). See the
[top-level README](../README.md) for how this module fits into the wider pipeline.

## What it does

For each pixel the IP computes four directional mean-absolute-Laplacian features over
the 7x7 neighborhood, quantizes each against seven Q2.14 thresholds into eight levels,
and packs them into a 12-bit context index. That index selects a filter class from the
4096-entry `cluster_map.hex`, which in turn selects one of 256 learned 7x7 kernels from
`filter_lut.hex`. No per-frame training — both LUTs are baked in at synthesis time. A software golden model
(`pc_golden.py`) reproduces the same fixed-point path and the notebook confirms hardware
output pixel-exact against it.

## AXI register map (`pc_axi_1_0`)

| Offset      | Field                              | Notes                                             |
|-------------|------------------------------------|---------------------------------------------------|
| `0x00–0x18` | 7 classification thresholds        | Q2.14                                             |
| `0x1C`      | `(H << 16) \| W`                   | frame geometry                                    |

Streaming is via AXI-Stream in and out (MM2S + S2MM DMA channels driven from the notebook).
Trained thresholds live in `pc_qp_group_*.npz` files under the project; loaded by the
notebook per QP group.

## Layout

| Path                                          | Contents                                                    |
|-----------------------------------------------|-------------------------------------------------------------|
| `fpga_pc.xpr`, `fpga_pc.srcs/`                | Vivado 2025.2 project + RTL sources                         |
| `../ip_repo/pc_axi_1_0/`                      | Packaged AXI IP referenced by the block design              |
| `pc_filter_bd_wrapper/`                       | Exported `.bit` + `.hwh` for PYNQ (no Vivado on board)      |
| `pc_notebook.ipynb`                           | Hardware validation notebook                                 |
| `pc_golden.py`                                | Fixed-point Python reference model, bit-exact with RTL      |
| `cluster_map.hex`, `filter_lut.hex`           | 4-cluster classifier map + per-cluster filter LUT           |
| `fpga_pc.srcs/sim_1/tb_pc_stream.v`           | Streaming testbench for the PC filter core                  |

## Results

Pixel-exact vs `pc_golden.py` across the training QP range (thresholds trained per
QP group; PC is designed to shine at higher QPs — see the top-level results table for
QP 160/170/180 PSNR gains). Below the training range PC underperforms; do not evaluate
outside the trained QP window without retraining.

## Quick start

Copy `pc_filter_bd_wrapper/` (both `.bit` and `.hwh`) to the PYNQ-Z2 alongside
`pc_notebook.ipynb`, open the notebook, run all cells. To re-synthesize the bitstream,
open `fpga_pc.xpr` in Vivado 2025.2 and run through implementation and
`write_bitstream`.
