#!/usr/bin/env python3
"""
Fig: PC filter word-length study.

(a) mean output Y-PSNR loss against an infinite-precision reference,
    15 runs (5 sequences x QP 160/170/180), for naive rounding and for
    rounding with the residual absorbed into the centre tap, with the
    filter's own restoration gain drawn as the scale that makes it meaningful.
(b) max |row sum - 1| after quantization -- the broken unit-sum constraint
    that drives the collapse in (a) below nine bits.

Two panels, one series each, shared x-axis: the two measures have unrelated
scales, so they must not share a y-axis.
"""
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FixedFormatter

INK, ACCENT, HILITE, MUTED = "#1a1a1a", "#1f4e79", "#c1440e", "#6b7480"

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "DejaVu Serif"],
    "font.size": 8,
    "axes.linewidth": 0.6,
    "xtick.direction": "in",
    "ytick.direction": "in",
})

d = np.load("sweep_fixed.npz", allow_pickle=True)
rows, bits, dc = d["rows"], list(d["bits"]), d["dc"]
fl = np.array([r["float"] for r in rows])
pre = np.array([r["pre"] for r in rows])
gain = float((fl - pre).mean())

loss = np.array([abs((np.array([r["taps"][b] for r in rows]) - fl).mean())
                 for b in bits])
lossr = np.array([abs((np.array([r["renorm"][b] for r in rows]) - fl).mean())
                  for b in bits])
i13 = bits.index(13)

fig, (axa, axb) = plt.subplots(
    2, 1, figsize=(3.4, 3.1), dpi=300, sharex=True,
    gridspec_kw={"height_ratios": [1.55, 1.0], "hspace": 0.16})

# ── (a) output quality ──────────────────────────────────────────────────────
axa.plot(bits, loss, "-o", color=ACCENT, lw=1.3, ms=3.4,
         mfc="white", mew=1.0, zorder=3, label="naive rounding")
axa.plot(bits, lossr, "-^", color=MUTED, lw=1.3, ms=3.6,
         mfc="white", mew=1.0, zorder=3, label="unit-sum preserved")
axa.legend(loc="lower left", fontsize=6.3, frameon=False,
           handlelength=1.6, borderpad=0.1, labelspacing=0.25)
axa.set_yscale("log")
axa.set_ylabel("Y-PSNR loss (dB)")
axa.set_ylim(5e-6, 20)

axa.axhline(gain, color=HILITE, lw=0.9, ls="--", zorder=2)
axa.text(16.4, gain * 1.6, f"break-even: loss = PC gain, {gain:.3f} dB",
         color=HILITE, fontsize=6.3, ha="right", va="bottom")

axa.plot([13], [loss[i13]], "o", ms=7, mfc="none", mec=HILITE, mew=1.3, zorder=4)
axa.annotate("shipped Q3.13\n$2.3\\times10^{-4}$ dB",
             xy=(13, loss[i13]), xytext=(14.9, 1.1e-3),
             fontsize=6.3, color=INK, ha="center", va="center",
             arrowprops=dict(arrowstyle="-", lw=0.5, color=MUTED,
                             shrinkA=1, shrinkB=4))
axa.text(0.028, 0.93, "(a)", transform=axa.transAxes,
         fontsize=7.5, va="top", color=INK)

# ── (b) the mechanism ───────────────────────────────────────────────────────
axb.plot(bits, dc * 100, "-s", color=ACCENT, lw=1.3, ms=3.0,
         mfc="white", mew=1.0, zorder=3)
axb.set_yscale("log")
axb.set_ylabel("DC-gain error (%)")
axb.set_xlabel("tap fractional bits")
axb.set_ylim(6e-3, 60)
# plain numbers, not powers of ten: this axis is a percentage and reads better
axb.yaxis.set_major_locator(FixedLocator([0.01, 0.1, 1, 10]))
axb.yaxis.set_major_formatter(FixedFormatter(["0.01", "0.1", "1", "10"]))
axb.yaxis.set_minor_formatter(FixedFormatter([]))
axb.set_xticks([6, 8, 10, 12, 14, 16])
axb.set_xlim(5.4, 16.6)

axb.plot([13], [dc[i13] * 100], "o", ms=7, mfc="none", mec=HILITE, mew=1.3, zorder=4)
axb.annotate("14% at six bits:\nunit sum broken",
             xy=(6, dc[0] * 100), xytext=(10.4, 19),
             fontsize=6.3, color=INK, ha="center", va="center",
             arrowprops=dict(arrowstyle="-", lw=0.5, color=MUTED,
                             shrinkA=1, shrinkB=3))
axb.text(0.028, 0.07, "(b)", transform=axb.transAxes,
         fontsize=7.5, va="bottom", color=INK)

for ax in (axa, axb):
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.grid(axis="y", lw=0.3, color="#dddddd", zorder=0)
    ax.set_axisbelow(True)

fig.savefig("fig_wordlength.pdf", bbox_inches="tight")
fig.savefig("fig_wordlength.png", bbox_inches="tight", dpi=220)
print("gain %.4f  loss@13 %.6f  ratio %.0fx  dc@13 %.3f%%"
      % (gain, loss[i13], gain / loss[i13], dc[i13] * 100))
