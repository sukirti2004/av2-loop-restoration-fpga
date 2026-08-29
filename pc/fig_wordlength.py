#!/usr/bin/env python3
"""
Fig: PC filter output quality vs tap word length (float reference).

Left axis  : mean output Y-PSNR loss against an infinite-precision reference,
             15 runs (5 sequences x QP 160/170/180), log scale.
Right axis : max |row sum - 1| after quantization -- the broken unit-sum
             constraint that drives the collapse below nine bits.
"""
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

INK, ACCENT, HILITE, MUTED = "#1a1a1a", "#1f4e79", "#c1440e", "#9aa4ad"

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
FLOOR = 1e-5
plot_loss = np.maximum(loss, FLOOR)

fig, ax = plt.subplots(figsize=(3.4, 2.5), dpi=300)

ax.plot(bits, plot_loss, "-o", color=ACCENT, lw=1.2, ms=3.2,
        mfc="white", mew=1.0, zorder=3, label="tap quantization loss")
ax.set_yscale("log")
ax.set_xlabel("tap fractional bits")
ax.set_ylabel("output Y-PSNR loss (dB)")
ax.set_xticks([6, 8, 10, 12, 14, 16])
ax.set_xlim(5.4, 16.6)
ax.set_ylim(5e-6, 5)

# restoration gain reference line: the scale that makes the loss meaningful
ax.axhline(gain, color=HILITE, lw=0.9, ls="--", zorder=2)
ax.text(15.4, gain * 1.35, f"PC restoration gain ({gain:+.3f} dB)",
        color=HILITE, fontsize=6.2, ha="right", va="bottom")

# shipped operating point
i13 = bits.index(13)
ax.plot([13], [plot_loss[i13]], "o", ms=6.5, mfc="none",
        mec=HILITE, mew=1.2, zorder=4)
ax.annotate("shipped Q3.13\n$2.3\\times10^{-4}$ dB",
            xy=(13, plot_loss[i13]), xytext=(11.4, 3.5e-5),
            fontsize=6.2, color=INK, ha="center",
            arrowprops=dict(arrowstyle="-", lw=0.5, color=MUTED))

# unit-sum / DC gain on the right axis
ax2 = ax.twinx()
ax2.plot(bits, dc * 100, "-s", color=MUTED, lw=1.0, ms=2.6,
         mfc="white", mew=0.8, zorder=2)
ax2.set_yscale("log")
ax2.set_ylabel("DC-gain error, max $|\\Sigma\\,\\mathrm{taps}-1|$ (%)",
               color=MUTED, fontsize=7)
ax2.tick_params(axis="y", colors=MUTED, labelsize=7)
ax2.set_ylim(5e-3, 5e2)
ax2.spines["right"].set_color(MUTED)
ax2.text(6.15, 20, "unit-sum broken", color=MUTED, fontsize=6.2,
         ha="left", va="bottom", style="italic")

for s in ("top",):
    ax.spines[s].set_visible(False)
    ax2.spines[s].set_visible(False)
ax.grid(axis="y", lw=0.3, color="#dddddd", zorder=0)
ax.set_axisbelow(True)

fig.tight_layout(pad=0.3)
fig.savefig("fig_wordlength.pdf", bbox_inches="tight")
fig.savefig("fig_wordlength.png", bbox_inches="tight", dpi=220)
print("gain %.4f  loss@13 %.6f  ratio %.0fx" % (gain, loss[i13], gain / loss[i13]))
