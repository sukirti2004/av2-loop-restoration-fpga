# PC Filter — Debugging Record

Chronological record of every bug found on hardware, its root cause, and the
method that exposed it. Written so the reasoning survives past the session it
happened in, and so the NS implementation can avoid the same traps.

---

## Summary table

| # | Symptom | Root cause | Found by |
|---|---|---|---|
| 1 | `RuntimeError: Unable to find metadata for bitstream` | `.hwh` base name differed from `.bit` | PYNQ error message |
| 2 | `DMA channel not started` / `start()` hung | PYNQ flag not set; DMA already running after overlay load | Reading DMA status registers directly |
| 3 | S2MM `DMAIntErr`, receive never completed | `M_AXIS_TLAST` hardcoded to `1'b0` | DMA status-register bit decode |
| 4 | Thresholds wrong, ctx saturated at 4095 | `T_Q2_14` hardcoded from an older model | Comparing `T_float × 16384` against the written values |
| 5 | −8.02 dB "gain" | See **Bug A** below | Synthetic test patterns + spatial shift scan |
| 6 | MAE 0.489, 51 % exact vs golden | Golden model truncated; RTL rounds | Arithmetic signature (~50 % off by exactly 1) |
| 7 | 6 wrong pixels per row (0.27 %) | See **Bug B** below | Streaming testbench |

---

## Bug A — pixel/tap misalignment (−8.02 dB)

**Symptom.** The filter destroyed the image: −8.02 dB average, 0 of 90 frames
improved. Errors were content-dependent — MAE 14.63 on texture, but constant
and ramp images passed exactly.

**Investigation.** Three synthetic tests separated the failure modes:

| Test | Result | What it ruled out |
|---|---|---|
| Constant image | Exact | Patch assembly, DC path |
| Vertical ramp | Exact | Row indexing |
| Horizontal ramp | Off by +3 columns | — |

A ±8-pixel spatial shift scan found the best match at (0, −3) with MAE 9.08 —
a shift alone did not explain it, so a second fault was layered on top.

**Root cause.** At the time, `px_d` in `pc_filter_core.v` was ungated while
several intermediate diagnoses were still in flight (stale LUTs in BRAM from a
retrained model, and wrong thresholds). The dominant error came from the model
mismatch: `cluster_lut.v` and `filter_lut.v` load their contents via
`$readmemh` at **synthesis** time, so the bitstream carried LUTs from the
pre-retraining model while the notebook compared against the new `.npz`.

**Fix.** Regenerate the hex files from the current `.npz`, re-synthesise, and
derive thresholds from the model rather than hardcoding them:

```python
T_Q2_14 = np.round(T_float * 16384).astype(int).tolist()   # never hardcode
```

**Lesson.** LUTs baked into the bitstream can silently disagree with the model
you are evaluating against, and nothing in the toolflow warns you. Either load
LUTs at runtime over AXI-Lite, or have the golden model read the same `.hex`
files the RTL does.

---

## Bug B — pixel delay chain gating (6 wrong pixels per row)

**Symptom.** After Bug A was fixed, agreement with the golden model reached
99.73 %. The residual was exactly **6 pixels per row, in the last 6 output
columns**, on every row of every sequence — 0.27 % of the frame.

**False start.** The first hypothesis was that the two-clock `valid_out` delay
in `line_buffer` collided with the `col_cnt` wrap. Traced cycle by cycle, that
turned out to be correct behaviour. A second hypothesis — Phase-1 BRAM writes
at `wr_ptr_d1` across the wrap — also held up. Reading the source was not
converging.

**What actually found it.** `tb_pc_stream.v`: stream a 32×16 random image
through the real `line_buffer` into `pc_filter_core`, compare every output beat
against `pc_golden.py`. At 32 wide the row wrap happens 16 times in a few
hundred cycles.

Two facts from simulation that hardware measurement could not show:

1. The six wrong outputs in a row were **all the same value** — 145, 145, 145,
   145, 145, 145 on row 3. Not misalignment (which gives different wrong
   values) but a **frozen datapath**.
2. Instrumenting `line_buffer` separately (checking `sr[3][3]` against the
   expected centre pixel at every `patch_valid`) gave **260 beats, 0 bad
   centres**. `line_buffer` was correct; the fault was in `pc_filter_core`.

**Root cause.** The `px_d` chain had been gated with `if (valid_in)`. That was
wrong, because **the taps path has a fixed 7-clock latency**: every stage in it
propagates its valid unconditionally —

```verilog
feature_compute : valid_s1 <= valid_in;  valid_s2a <= valid_s1;  ...
quantizer_ctx   : valid_out <= valid_in;
cluster_lut     : valid_out <= valid_in;
filter_lut      : valid_out <= valid_in;
```

The `if (valid)` guards in those modules sit only on the **data** registers.
They hold stale data during bubbles to save power, but the valid — and the data
travelling with it — still advances one stage per clock. Bubbles pass straight
through.

Gating `px_d` made its latency **7 valid beats** rather than **7 clocks**. Those
are equal only when valid is continuous. `line_buffer`'s `valid_out` is low for
the first 6 columns of every row (`col_cnt < 6`), so each row's gap pushed
`px_d` 6 clocks behind the taps, and the MAC re-used the same stale patch for
the last 6 outputs of the row.

**6-clock gap → 6 wrong pixels per row.** The numbers matched exactly.

**Fix.** Revert to ungated:

```verilog
reg [49*8-1:0] px_d [0:6];
always @(posedge clk) begin
    px_d[0] <= pixels_flat;
    px_d[1] <= px_d[0];
    ...
    px_d[6] <= px_d[5];
end
```

**Verification.** `tb_pc_stream.v`: gated → 59/260 mismatches, all in the last
6 output columns. Ungated → **0/260, bit-exact**.

**Lesson.** In a pipeline where valid propagates unconditionally, every
parallel delay path must advance per **clock**, not per **valid beat**. Mixing
the two conventions desynchronises them by exactly the length of each valid
gap. Gating a delay line looks like a safe optimisation and is not.

---

## Bug C — truncation vs rounding (MAE 0.489)

**Symptom.** Uniform MAE ≈ 0.49 with ≈ 51 % exact match across 13 sequences of
very different content. Uniformity across content ruled out a logic bug.

**Root cause.** `mac_engine.v` rounds:

```verilog
assign shifted = (final_sum_r + 30'sd4096) >>> 13;
```

The golden model truncated (`s >> 13`). Round-to-nearest and truncation differ
by exactly 1 whenever the discarded fraction is ≥ 0.5 — about half of all
values. Predicted 50 % / MAE 0.5; measured 51.2 % / 0.489.

**Fix.** `(s + 4096) >> 13` in the golden model.

**Also worth knowing.** Truncation carries a systematic −0.5 LSB bias, adding
0.25 to MSE. At ~26 dB that is ≈ −0.007 dB — the same order as the filter's
measured gain, so the rounding fix was not cosmetic.

---

## Verification method that worked

Ordered by how much each one actually contributed:

1. **Streaming testbench against a bit-exact reference.** The only test that
   exposed Bug B. Small image (32×16) so row wraps repeat quickly; random
   pixels so many filter contexts are exercised.
2. **Synthetic patterns.** Constant / horizontal ramp / vertical ramp isolate
   DC, column and row behaviour independently. Cheap, and they localise a fault
   to one axis immediately.
3. **Spatial shift scan.** Correlating output against the reference over ±8
   pixels distinguishes "shifted" from "scrambled".
4. **Arithmetic signatures.** A uniform ±1 difference at ~50 % frequency is
   rounding, not logic. Reasoning from the error *distribution* rather than its
   magnitude named Bug C without any simulation.
5. **Bisecting the pipeline.** Checking `line_buffer` alone (patch centre vs
   expected pixel) halved the search space in one run.

## What did NOT work

- **Single-patch testbenches.** `pixels_flat` held static means any delay depth
  or gating returns the same value. Invisible to Bugs A and B.
- **Continuous valid.** Both bugs required *gaps* in valid to manifest.
- **Module-level tests in isolation.** `line_buffer` and `pc_filter_core` each
  passed their own testbenches. Bug B lived in the interaction.
- **Reading the source.** Two careful cycle-by-cycle traces of `line_buffer`
  produced two wrong hypotheses. Simulation found it in one run.

---

## Checklist for NS

- [ ] Streaming testbench against a bit-exact golden model **before** synthesis
- [ ] Test image with varying pixel values, not constant or ramp
- [ ] Verify behaviour with **gaps** in valid, not just continuous streaming
- [ ] Audit every parallel delay path: does it advance per clock or per valid
      beat? Match whatever the main path does.
- [ ] Golden model rounding must match RTL rounding exactly
- [ ] If LUTs are baked in via `$readmemh`, have the golden model read the same
      `.hex` files — do not re-derive from the source `.npz`
- [ ] Remove absolute paths from `$readmemh` before sharing the project
