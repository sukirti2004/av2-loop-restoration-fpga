# RDO Selector — FPGA Implementation

Rate-distortion-optimized mode selector for AV2 loop restoration. Chooses one of three
candidates per 256×256 restoration unit (NONE / PC / NS) by minimizing
`cost = MSE + λ·R`, run as a custom AXI IP on the PL side of a PYNQ-Z2 (Zynq-7020).
See the [top-level README](../README.md) for how this module fits into the wider pipeline.

## What it does

The block design ties six AXI-DMA channels to the PS. Four MM2S channels feed the RDO
IP: HR reference, pre-LR (NONE candidate), PC-filtered candidate, NS-filtered candidate.
The remaining two are the NS-filter and PC-filter round-trip channels so the notebook
can run those IPs in the same overlay. The RDO IP computes per-RU cost for each
candidate on-chip, picks the winner (tie-break NONE > PC > NS), and exposes the full
selection bitmap in read-only registers. The notebook blends the candidates in software
using that bitmap and reports HW-vs-SW agreement against a Python MSE-argmin golden.

## AXI register map (`rdo_filter_axi_1_0`)

| Offset            | Field                              | Notes                                           |
|-------------------|------------------------------------|-------------------------------------------------|
| `0x00`            | Control — bit0 CLEAR, bit2 SOF     | write CLEAR before a frame, SOF pulse to arm    |
| `0x04`            | `LAMBDA`                           | integer scale factor for the rate term          |
| `0x08 / 0x0C / 0x10` | `R_NONE / R_PC / R_NS`          | integer per-mode rate charges                   |
| `0x14`            | `STATUS`                           | done / busy                                     |
| `0x18 – 0x2C`     | `SEL_{NONE,PC,NS}_{LO,HI}`         | read-only 3×64-bit per-mode winner bitmap       |

Cost: `cost_x = mse_x + LAMBDA · R_x`, evaluated in integer SSE units per RU. Setting
LAMBDA = 0 gives the oracle (pure MSE argmin) selection.

## Layout

| Path                                            | Contents                                                    |
|-------------------------------------------------|-------------------------------------------------------------|
| `rdo_filter.xpr`, `rdo_filter.srcs/`            | Vivado 2025.2 project + RTL sources (all in-project, no `ip_repo/` dependency) |
| `rdo_filter_bd_wrapper/`                        | Exported `.bit` + `.hwh` for PYNQ (no Vivado on board)      |
| `rdo_notebook.ipynb`                            | End-to-end validation notebook                              |

## Results

15/15 runs at **100.000 %** HW-vs-SW per-RU agreement across 5 test sequences
(CrowdRun, OldTownCross, PedestrianArea, Riverbed, RushFieldCuts) × three QPs
(160 / 170 / 180). Mean per-QP PSNR gains vs pre-LR and a rate-sweep table live in the
[top-level README](../README.md#results); the notebook produces both tables plus per-QP
bar charts.

## Quick start

Copy `rdo_filter_bd_wrapper/` (both `.bit` and `.hwh`) to the PYNQ-Z2 alongside
`rdo_notebook.ipynb`, open the notebook, run all cells. The notebook is the full
end-to-end path: it trains per-RU NS taps in software, runs PC and NS on hardware,
feeds the four streams into the RDO IP, and reports agreement + PSNR + rate-sweep
behavior. To re-synthesize the bitstream, open `rdo_filter.xpr` in Vivado 2025.2 and
run through implementation and `write_bitstream`.

Note: the large `rdo_filter_bd_wrapper.dcp` synthesis checkpoint (~85 MB, inside
`rdo_filter.srcs/utils_1/imports/synth_1/`) is intentionally excluded — regenerate it in
Vivado by re-running synthesis on `rdo_filter_bd_wrapper` from the sources above.
