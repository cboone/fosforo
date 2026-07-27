# 0011. AUv2 first, other formats deferred

**Status:** Accepted

## Context

Logic Pro loads only Audio Units, and Audio Units come in two incompatible shapes. AUv2 is the classic `.component`, a bare dynamic library. AUv3 is the modern rewrite, delivered as an **app extension** rather than a library, and every difference between them flows from that one architectural fact.

AUv3 would buy: reach into the whole Apple ecosystem, since the same extension runs on iOS and iPadOS (the only path to an iPad version, which for a touch-manipulable visual instrument is genuinely appealing); process isolation, since an app extension runs out-of-process, so a crash takes down the extension rather than the user's session, which is a real robustness gain for live GPU code specifically; alignment with the format Apple is actively investing in; and a Mac App Store distribution path.

It would cost: more elaborate packaging (container app, entitlements, sandbox), a cross-process compositing path for the GUI, and, paradoxically, **narrower** desktop host compatibility, since some hosts are fussier about AUv3 than AUv2.

## Decision

Ship AUv2 first. Treat AUv3, VST3, AAX, and standalone as later toggles, all of which clap-wrapper can emit from unchanged source.

## Consequences

The clarification that makes this decision easy, and which is worth stating plainly because it is commonly misunderstood: **AUv3 offers no audio-quality or visual-quality improvement over AUv2.**

The format difference lives entirely in the packaging and lifecycle layer, covering where the plugin runs, how it is delivered, and how it fails. It does not touch the signal path or the rendering path. Audio quality is a function of the DSP, the numeric precision, and the buffers the host provides, all of which are identical across formats because they are the same code reached through a different front door. Visual quality is a function of Metal and the shaders, which neither format touches.

If anything, AUv3's out-of-process model adds one boundary to both the audio path and the GUI compositing path, so any lean on *output* quality tilts very slightly toward in-process AUv2.

This is liberating for planning: because output quality lives entirely in the layer shared across all formats, the format choice can be made purely on packaging merits with zero worry about compromising sound or pixels. Ship the easy-to-load AUv2 now; flip the AUv3 toggle if and when iPad reach, crash isolation, or the App Store becomes worth its packaging cost.

Note that AUv3 additionally requires the Xcode CMake generator, because the `.appex` is linked as an app-extension product and signed by Xcode. That is a further reason not to take it on before it is wanted.
