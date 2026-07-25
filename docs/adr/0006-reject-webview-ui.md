# 0006. Reject a WebView UI

**Status:** Accepted

## Context

Contemporary plugins increasingly use system WebViews for their interfaces, including through a documented JUCE 8 pathway. The option needed ruling in or out explicitly so it is not revisited.

Two common objections do **not** hold and should be set aside. These are not Electron: the WebView is the operating system's own component (WebKit on macOS), not a bundled Chromium, so the "hundreds of megabytes per plugin" complaint does not apply. And the stability argument runs the *other* way: the DSP stays native on the audio thread, and a WebView living in another process is structurally incapable of causing the classic UI-induced audio dropout.

The real costs are different. Each editor spawns an out-of-process web content process, which degrades at high instance counts, and there is a startup and reload latency cost. There is also a genuine and underdiscussed security surface: the bridge is a scripting-to-native call path inside a process holding the DAW's entitlements, and WebView-choosing plugins tend to be the ones pulling remote content and an npm dependency tree, importing the JavaScript supply-chain threat model into a category with little security-review culture.

## Decision

Do not use a WebView. Own the view and render with the GPU.

## Consequences

The disqualifying argument is specific to a **live measurement instrument**, and it is architectural rather than aesthetic.

The phosphor renderer needs a lock-free, audio-rate buffer feeding a GPU pass on a schedule the plugin controls. The JavaScript-to-native bridge is asynchronous and serializing, with no cheap path to move an audio-rate sample buffer across it. Worse, compositing happens on the WebView's schedule rather than the plugin's, which introduces variable lag into a tool whose entire purpose is measurement. Dragging a cursor along a trace and reading an instantaneous phase value requires input and rendering on a timeline the instrument owns.

A WebView remains a reasonable trade for a different, control-panel-shaped, visualization-light plugin. There it is a hiring-and-iteration-speed decision more than a technical one. It is not that here.

For context on where well-rendered plugins actually sit: they are mostly on a custom GPU renderer track, not the web one. FabFilter has always used an in-house framework. Bitwig went through a comparable GPU rewrite. **Visage**, the MIT-licensed GPU UI library extracted from Vital, is the notable recent development and uses signed distance fields, which is the right structural answer to Retina crispness because a shape defined as a distance field is resolution-independent by construction.

Visage was evaluated as a possible dependency and **rejected on that basis**: it is C++ with no C API, so it is not consumable from Zig. It remains useful prior art, and the SDF approach is adopted independently for text rendering.
