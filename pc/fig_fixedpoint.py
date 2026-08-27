#!/usr/bin/env python3
"""
fig_fixedpoint.pdf — fixed-point design-space figure for the PC filter paper.

(a) Output Y-PSNR loss against an infinite-precision reference, as a function of
    filter-tap fractional word length. The horizontal line is the loss floor
    imposed by the Q2.14 classification thresholds alone; the shaded region to
    its right is where the datapath is already below that floor, so added tap
    precision cannot change the output.

(b) Per-sequence PC gain over pre-LR in float vs in the shipped fixed point.
    On low-noise content the classifier quantization is larger than the whole
    filter gain, flipping PC from beneficial to harmful.

Inputs : sweep_results.npz (from sweep_wordlength.py)
Outputs: fig_fixedpoint.pdf / .png
"""
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SWEEP = "sweep_results.npz"

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Nimbus Roman", "DejaVu Serif"],
    "font.size": 8, "axes.labelsize": 8, "axes.titlesize": 8,
    "xtick.labelsize": 7, "ytick.labelsize": 7, "legend.fontsize": 7,
    "axes.linewidth": 0.6, "xtick.major.width": 0.6, "ytick.major.width": 0.6,
    "lines.linewidth": 1.2, "grid.linewidth": 0.4, "grid.alpha": 0.3,
    "hatch.linewidth": 0.5,
})

INK, ACCENT, HILITE, MUTED = "#1a1a1a", "#1f4e79", "#c1440e", "#9aa4ad"
BAND = "#ebebeb"          # neutral grey: reads as a region, not as a third series

d = np.load(SWEEP, allow_pickle=True)
rows, bits = d["rows"], [int(b) for b in d["bits"]]

fig, (ax1, ax2) = plt.subplots(
    2, 1, figsize=(3.45, 4.35),
    gridspec_kw={"height_ratios": [1.0, 0.95], "hspace": 0.78})

# ══ (a) tap word length vs output PSNR loss ════════════════════════════════
tap_loss  = np.array([np.mean([r["float"] - r["taps"][b] for r in rows]) for b in bits])
thr_floor = float(np.mean([r["float"] - r["thr"] for r in rows]))
plot_loss = np.maximum(tap_loss, 6e-5)

# first bit width at which the datapath drops below the classifier floor
cross = next(b for b, t in zip(bits, tap_loss) if t < thr_floor)

ax1.axvspan(cross, 16.6, color=BAND, zorder=0)
ax1.text(16.35, 1.55, "classifier-limited", color=MUTED, fontsize=6.6,
         ha="right", va="center", style="italic")

ax1.axhline(thr_floor, color=HILITE, lw=1.1, zorder=3)
ax1.text(6.1, thr_floor * 1.45, "Q2.14 threshold floor", color=HILITE,
         fontsize=6.8, ha="left", va="bottom")

ax1.semilogy(bits, plot_loss, "-", color=ACCENT, marker="s", ms=3.0,
             zorder=4, label="tap quantization only")

i13 = bits.index(13)
ax1.plot([13], [plot_loss[i13]], marker="s", ms=5.0, color=HILITE, zorder=6)
ax1.annotate("Q3.13 (shipped)", xy=(13, plot_loss[i13]), xytext=(11.4, 8e-4),
             color=HILITE, fontsize=6.8, ha="center", va="center",
             arrowprops=dict(arrowstyle="->", color=HILITE, lw=0.7,
                             shrinkA=1, shrinkB=3))
ax1.annotate("DC-gain error\n(unit-sum broken)", xy=(7, plot_loss[1]),
             xytext=(8.6, 0.40), color=INK, fontsize=6.5, ha="left", va="center",
             arrowprops=dict(arrowstyle="->", color=INK, lw=0.6,
                             shrinkA=1, shrinkB=3))

ax1.set_xlabel("filter-tap fractional word length (bits)")
ax1.set_ylabel("Y-PSNR loss vs float (dB)")
ax1.set_xlim(5.4, 16.6)
ax1.set_ylim(5e-5, 3.0)
ax1.set_xticks([6, 8, 10, 12, 14, 16])
ax1.grid(True, which="major", color=MUTED, zorder=1)
ax1.legend(frameon=False, loc="lower left", handlelength=1.6,
           borderaxespad=0.4)
ax1.set_title("(a)  Y-PSNR loss vs. filter-tap word length",
              loc="left", color=INK, pad=5)
for s in ("top", "right"):
    ax1.spines[s].set_visible(False)

# ══ (b) per-sequence: float gain vs shipped fixed-point gain ═══════════════
seqs = list(dict.fromkeys(r["seq"] for r in rows))
short = {"CrowdRun_1920x1080p50": "CrowdRun",
         "OldTownCross_1920x1080p50": "OldTown",
         "PedestrianArea_1920x1080p25": "Pedestrian",
         "Riverbed_1920x1080p25": "Riverbed",
         "RushFieldCuts_1920x1080_2997": "RushField"}

pre_psnr = {s: np.mean([r["pre"] for r in rows if r["seq"] == s]) for s in seqs}
seqs = sorted(seqs, key=lambda s: pre_psnr[s])      # noisiest -> cleanest, left to right

g_float = np.array([np.mean([r["float"]   - r["pre"] for r in rows if r["seq"] == s]) for s in seqs])
g_fixed = np.array([np.mean([r["shipped"] - r["pre"] for r in rows if r["seq"] == s]) for s in seqs])

x, w = np.arange(len(seqs)), 0.34
ax2.axhspan(-0.10, 0, color=BAND, zorder=0)          # "harmful" half-plane
ax2.bar(x - w/2, g_float, w, color=ACCENT, label="float reference", zorder=3)
ax2.bar(x + w/2, g_fixed, w, color=HILITE, label="shipped fixed point", zorder=3,
        hatch="////", edgecolor="white", linewidth=0.0)
ax2.axhline(0, color=INK, lw=0.8, zorder=4)

for xi, gf in zip(x, g_fixed):
    if gf < 0:
        ax2.annotate("sign flip", xy=(xi + w/2, gf), xytext=(xi + w/2, gf - 0.019),
                     color=HILITE, fontsize=6.2, ha="center", va="top",
                     arrowprops=dict(arrowstyle="-", color=HILITE, lw=0.5,
                                     shrinkA=1, shrinkB=1))

ax2.set_xticks(x)
ax2.set_xticklabels([f"{short[s]} ({pre_psnr[s]:.1f})" for s in seqs],
                    rotation=22, ha="right")
ax2.set_xlabel("sequence (pre-LR baseline PSNR, dB)", labelpad=2)
ax2.set_ylabel("PC gain over pre-LR (dB)")
ax2.set_xlim(-0.62, len(seqs) - 0.38)
ax2.set_ylim(-0.062, 0.098)
ax2.set_yticks([-0.05, 0.0, 0.05])
ax2.grid(True, axis="y", color=MUTED, zorder=1)
# legend on its own line between title and plot — never over the bars
ax2.legend(frameon=False, loc="lower center", bbox_to_anchor=(0.5, 1.005),
           ncol=2, handlelength=1.3, columnspacing=1.4, borderaxespad=0.0)
ax2.set_title("(b)  PC gain: float vs. shipped fixed point",
              loc="left", color=INK, pad=17)
for s in ("top", "right"):
    ax2.spines[s].set_visible(False)

fig.savefig("fig_fixedpoint.pdf", bbox_inches="tight", pad_inches=0.02)
fig.savefig("fig_fixedpoint.png", dpi=230, bbox_inches="tight", pad_inches=0.02)

print(f"threshold floor {thr_floor:.4f} dB | crossing at {cross} bits | "
      f"tap loss @13 {tap_loss[i13]:.5f} dB")
for s, a, b in zip(seqs, g_float, g_fixed):
    print(f"  {short[s]:11s} float {a:+.4f}  fixed {b:+.4f}"
          + ("   SIGN FLIP" if a > 0 > b else ""))
