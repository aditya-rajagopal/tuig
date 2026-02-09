---
title: Try inlining full style and see if it improves performance
status: done
priority_value: 50
priority: medium
owner: aditya
created: 2026-02-08T21:16:47Z
completed: 2026-02-08T21:38:17Z
tags: 
- perf
---

Things to try:
- Baseline: Current implementation: cells store style IDs, styles live in Style.Sheet.
- Inline: full style packed into each cell, cell expanded to 128 bits.
- Split Style: cell reduced to 32-bit data, style stored in a parallel framebuffer array.

[Baseline Metrics](baseline.csv)
[Inline Metrics](inline.csv)
[Split Metrics](split.csv)


| Comparison | Time Median | Cycles | Instructions | Cache Misses | Branches | Branch Misses |
|---|---:|---:|---:|---:|---:|---:|
| Inline vs Baseline | +3.4% | +5.8% | +5.6% | +16.9% | +2.3% | +7.9% |
| Split  vs Baseline | +4.1% | +5.2% | +12.5% | +46.8% | +11.5% | +9.2% |
| Split  vs Inline | +0.7% | -0.5% | +6.5% | +25.6% | +9.0% | +1.2% |


Result:
- Both new designs regress vs baseline on overall performance.
- Inline is consistently better than Split in most metrics.
- Split only improves cycles slightly vs Inline, but looses on pretty much everything else.
- Style-heavy diff_redraw was the worst offender


Most likely doing all the extra inline comparisons and having more parallel arrays we are caching is not that great.
Espeically in the split the cache misses are pretty wild.
Also after using the new design it does not seem that much better to use the API setting the style directly.

Just keeping the current style sheet API and making it a bit ncier to use.
