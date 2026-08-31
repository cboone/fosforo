# 0017. The vertical axis is absolute and never rescales itself

**Status:** Accepted

## Context

Issue [#38](https://github.com/cboone/fosforo/issues/38) draws the first trace, and drawing one forces a question nothing before it had to answer: where does a sample of a given value land on the screen, and what happens to one that will not fit.

The tempting answer is to fit the signal to the window. Almost every waveform display in a DAW does some version of it: a peak-normalized overview, an auto-ranging analyzer, a meter that expands its scale when the material is quiet. It always looks better in a screenshot, because the trace fills the frame no matter what is playing.

It is also the one thing this project cannot do. [ADR 0012](./0012-phosphor-oscilloscope-first.md) makes the deliverable a measurement instrument rather than a visualizer, and an instrument whose scale moves without being asked reports a quiet signal and a loud one with the same picture. Someone reading it cannot tell whether the trace grew because the level rose or because the display rescaled, which means the display has stopped carrying the one quantity it exists to show.

The decision has to be recorded rather than merely implemented, because the implementation is three lines of shader arithmetic and the argument for changing it will arrive repeatedly and will always sound reasonable.

## Decision

**The vertical axis is fixed and absolute.**

- Full scale is a sample value of ±1.0, and it is stated rather than inferred.
- The mapping from sample value to screen position is constant. It does not depend on the window's contents, on recent peaks, on a running average, or on anything else the signal does.
- A sample beyond full scale is shown as beyond full scale. It is neither hidden nor quietly folded back into range.

## Consequences

**What this forbids.** Auto-gain, auto-ranging, per-window or per-frame peak normalization, and any soft compression of the region above full scale. A display that applies any of these is reporting a level it was not given, and none of them may be added without an ADR superseding this one.

**Over-scale rails rather than vanishing, and the rail is visible.** Clamping is not the obvious implementation and is the right one. Left to the rasterizer, a clipped line strip does not lose the trace, it loses the *peaks*: segments crossing the boundary still draw up to it and segments wholly beyond it do not, so a hot signal reads as a quieter signal with gaps. That is a worse falsehood than either railing or vanishing, because it is legible and wrong. The rail also sits inside the drawable rather than on its edge, since a one-pixel line centred on the framebuffer boundary may rasterize to nothing and a railed signal that draws nothing reads as an absent one.

**The instrument says "at or above full scale" and refuses to say how far above.** That is a real limitation and it is the honest one at this scale: a rail is unambiguous, and an over that draws further and further off-screen is not information anyone can read. Making the amount of overshoot legible is a clip indicator's job, not the axis's.

**A reference has room to move; the principle does not.** Phase 4's parameters may add a user gain control and a later phase may add a graticule to read against. Both change *where* the reference sits and neither touches the rule that it is stated, constant, and independent of the signal. This ADR therefore fixes no numbers. The constants live in `src/gpu/iface.zig` as `trace_full_scale` and `trace_rail`, with the arithmetic that makes them non-arbitrary, and a test in `src/clap/gui.zig` ties the rail to the smallest editor `clampSize` permits.

**A fixed axis has a floor, and it is arithmetic.** One backing pixel of excursion needs a sample of `1 / (trace_full_scale * height / 2)`, which is about -54 dBFS at the default editor on a 2x display and about -42 dBFS at the smallest editor on a 1x one. Below that a signal reads as flat. An auto-ranging display would not have that floor, which is the one genuine thing given up here, and it is given up knowingly: a scope that shows -80 dBFS as a full-height waveform has told a bigger lie than one that shows it as a flat line.

**This is not in tension with [ADR 0007](./0007-renderer-simulates-a-crt.md).** That ADR makes brightness a readout of the signal's statistics, and this one makes displacement a readout of its amplitude. Both say the same thing from different directions: what appears on screen is a measurement rather than a composition. A hardware scope's volts-per-division knob is set by a person and stays where it is put, and nothing about simulating the tube implies simulating an operator who keeps turning it.

## Amended by issue #60: the question was asked, and there is no tension

A tonemap *is* soft compression, and this ADR forbids "any soft compression of the region above full scale". The distinction that saves it is the one this document's own closing paragraph already draws: that clause governs **displacement**, and a tonemap governs **brightness**. They are two axes, and neither derives anything from the signal's own statistics.

Recorded rather than left implicit because the sentence reads like a prohibition on exactly what #60 built, and someone will quote it. [ADR 0019](./0019-brightness-is-a-fixed-transfer-function.md) carries the decision and pre-refuses the thing that *would* breach this one: an exposure or white point derived from the frame's measured peak energy, which is auto-gain on the brightness axis and needs an ADR superseding 0019 to add.

The reasoning transfers in the other direction too, which is the part worth having. #60's white point is the brightness axis's **rail**: above it the display says "at or above" and refuses to say how far, which is this ADR's own criterion for `trace_rail`. `scripts/measure-trace` reports the two the same way.
