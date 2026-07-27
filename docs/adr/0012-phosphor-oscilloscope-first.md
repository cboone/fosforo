# 0012. First deliverable is the phosphor oscilloscope only

**Status:** Accepted

## Context

The design brainstorm deliberately refused to narrow "an oscilloscope" into one product. It laid out a wide menu of lenses in two families: faithful monitors (the phosphor trace, musically-aware triggering, a measurement layer, multi-instance alignment, stereo monitoring) and framings freed from the assumptions a 1950s cathode-ray tube imposed (delay-embedding phase-space attractors, reassigned time-frequency surfaces, statistical density and eye diagrams, scrub-anywhere records).

The unifying principle it arrived at is real and worth keeping: the signal is one thing, the representations are lenses, and the instrument's job is to make swapping lenses fluid. But breadth in a menu is not a mandate to build all of it.

## Decision

The first deliverable is the phosphor oscilloscope **only**: the velocity-weighted persistent trace, musically-aware triggering, and a measurement layer. Ship it, then reassess.

## Consequences

**What this defers, explicitly.** These are deliberate omissions, not oversights:

- **Multi-instance alignment.** Two instances discovering each other, sharing buffers keyed to the host playhead, overlaying traces, and showing a live cross-correlation curve whose peak marks the offset maximizing low-end summation. This is the most differentiated idea in the brainstorm and the strongest candidate for the phase after v0.1.0. It is deferred because it is architecturally the most demanding early feature, not because it is unimportant.
- **Family B lenses:** phase-space attractor, constant-Q with reassignment or synchrosqueezing, aligned statistical density and eye diagrams, scrub-anywhere record, waterfall.
- **Stereo monitoring:** banded correlation-history plot and X-Y vectorscope.

**Why this ordering is safe.** Every deferred lens shares the same signal tap and the same renderer. A phase-space trajectory is still a path splatted into a density buffer; a spectrogram is still a texture. Later lenses layer onto the Phase 3 renderer rather than replacing it, so nothing built now becomes waste.

**What the trace is genuinely best at.** The brainstorm's own conclusion is that the mistake was never the trace. Amplitude against linear time is the right representation for a narrow but important class of questions: the exact shape of a single transient, spotting a lone glitch, seeing a discontinuity. The mistake would be building an instrument offering *only* the trace. Building the trace *first*, well, is not that mistake.

**The guardrail to carry forward.** The failure mode across the whole Family B menu is chasing novelty into representations that look striking and measure worse. A measurement instrument that sacrifices measurement has lost the plot. Depth and perspective in particular are the enemies of reading an exact value.
