# 0009. Runtime MSL compilation is the single runtime path

**Status:** Accepted

## Context

Metal shaders can be supplied two ways: compiled offline into a `.metallib` with `xcrun metal` and loaded as a binary, or compiled at runtime from a source string via `newLibraryWithSource:options:error:`.

Offline compilation catches syntax errors at build time and avoids a one-time compile cost. Runtime compilation keeps the build hermetic and makes shader hot-reload possible.

A relevant environmental fact: since Xcode 16, Apple ships the Metal toolchain as an on-demand component rather than in the base installer, so `xcrun metal` is absent from a stock Xcode install until explicitly downloaded. A build depending on it would fail confusingly for any contributor who had not run that step.

## Decision

Compile shaders at runtime from source embedded in the binary with `@embedFile`. This is the only path used at runtime.

Additionally use the Metal toolchain as a **validation tool**, never as a build dependency.

## Consequences

**The build stays hermetic.** `zig build` needs no Xcode toolchain component and no Metal compiler. This matters for CI and for anyone cloning the repository.

**Shader hot-reload becomes possible**, and on a project where the renderer *is* the product, this is a genuine force multiplier. Editing a fragment shader and seeing the trace change without relaunching the host is worth more than the few milliseconds of one-time compile it costs. Debug builds reload from disk; release builds use the embedded source.

**The gap this leaves is closed deliberately.** Runtime compilation means a malformed shader surfaces when the GUI opens rather than when the code is built. So `zig build validate-shaders` type-checks each shader with `metal -x metal -fsyntax-only`.

That step is deliberately **not** wired into `zig build test`. Making the default test path depend on an on-demand Xcode component would reintroduce exactly the non-hermetic build this ADR exists to avoid, and would fail for any contributor who had not downloaded the toolchain. It is a separate step, run explicitly and in CI.

Verified: `metal -fsyntax-only` reading from stdin accepts a valid fragment shader and correctly rejects an invalid one with a precise diagnostic. Also verified that runtime compilation works from Zig, resolving a named fragment function from a source string.

If the one-time compile cost ever proves noticeable, precompiling to `.metallib` for release builds is available as an optimization. It is not needed now, and adopting it would mean maintaining two runtime paths.

## Amended by issue #61: what reloading from disk actually costs

The Consequences above promise that "debug builds reload from disk; release builds use the embedded source" and say nothing about which disk, or what the promise costs. [#61](https://github.com/cboone/fosforo/issues/61) implemented it. Nothing here is superseded; what follows is the detail that sentence deferred.

### The compile is two numbers, not one, and they differ by a factor of three hundred

The paragraph above says "the few milliseconds of one-time compile it costs", which was never measured. It is now, and the figure depends entirely on Metal's cache.

| Case                                          | Library     | Pipelines     | When it applies                              |
| --------------------------------------------- | ----------- | ------------- | -------------------------------------------- |
| Cache hit, source seen before on this machine | 0.04 ms     | 0.10 ms       | Every launch of an unchanged build           |
| Cache miss, steady state                      | 34 to 43 ms | 0.2 to 0.8 ms | Every hot reload, by definition              |
| Cache miss, first compile in the process      | 57 to 68 ms | 0.2 to 0.8 ms | The extra is the XPC connection being set up |

Metal keys its cache on the source and it survives across processes, so `set_parent` ordinarily waits 0.14 ms on this and the accumulation textures dominate `init`. `Pipelines` in `src/gpu/metal/renderer.zig` used to call the compile "the most expensive thing `init` does", which is true only on a cold cache and has been corrected in place.

**The number that matters is the miss**, because a reload has changed the source by definition. 40 ms is five vsyncs at 120 Hz, and `Editor.tick` holds its `Gate` across its whole body, so compiling inside a tick would busy-spin the host's main thread for up to 40 ms whenever an editor closed during one. That is what puts the compile on a thread of its own rather than in the render loop, and it is a measurement rather than a preference.

**That placement is enforced rather than merely intended.** A debug-only `threadlocal` marks any thread that has entered the render path, and `buildPipelinesFromSource` asserts it is unset, which is `platform.assertNotMainThread` from the side nothing previously guarded. It exists because the harness cannot see the defect: 40 ms in a tick is invisible to a frame counter with a two-second timeout, so a compile that drifted back into the render loop would report a clean run. [#59](https://github.com/cboone/fosforo/issues/59) defers the same question about its own upsampling and inherits the guard.

### Two gates, and neither substitutes for the other

`build.zig` emits the absolute path only when `optimize == .Debug`; `src/gpu/metal/shader.zig` reads it only when `builtin.mode == .Debug and !builtin.is_test`.

The first decides whether the bytes exist in the binary. Leaving that to the source gate would make "no shipped binary carries a path into somebody else's worktree" a claim about the optimizer, which is precisely the standard `src/build_info.zig` refuses in the other direction for its marker, and the `clap-wrapper` job now asserts the negative with the marker as its positive control.

The second decides whether anything reads it, which `build.zig` cannot do: an empty option still links the watcher, the reader and a 64 KiB buffer into a release binary. **And only the source gate can carry `!builtin.is_test`.** `zig build test` is a Debug build, so `builtin.mode` alone would put filesystem reads inside the hermetic test path this ADR exists to protect. One test asserts exactly that and fails if the term is dropped.

### What a debug binary now carries that a release one does not

**A machine-specific absolute path**, which is the first byte in this project that differs between two developers building the same commit. It is confined to Debug, Debug is never shipped, and CI proves the confinement. `FOSFORO_SHADER_PATH` overrides it, which is what survives a moved worktree with no rebuild, lets one installed debug bundle be pointed at whichever worktree is being iterated in, and makes the whole thing testable at all. It is invisible in Logic twice over, and that costs nothing: an app launched through LaunchServices does not inherit a shell's environment, Logic cannot be launched from a terminal, and the Audio Unit is `--release=fast` from CMake so it has no reload path under any circumstances.

### The fallback rule, which has one non-obvious case

A file that is missing, malformed, or compiles without defining what the pipelines ask for all fall back to the **embedded copy**, and the editor opens. A set-but-missing `FOSFORO_SHADER_PATH` falls back to the embedded copy rather than to the build option, because the developer said which file they meant and quietly substituting a different one would be worse than saying so. A relative path is refused outright: a plugin's working directory belongs to the DAW, so `shaders/scope.metal` is right only when REAPER happened to be launched from a worktree.

### What reloading does not check, stated so it is not assumed

**Nothing validates a hot-reloaded shader's binding indices.** The `bindingIndexAfter` tests, the `TraceUniforms` layout test, and the `scripts/measure-trace` constants test all read the **embedded** copy at comptime, which is correct: a test about a file that can change between a build and a frame would say nothing. A file swapped in at runtime gets `buildPipeline`'s missing-function check and nothing else, so a moved `[[buffer(N)]]` draws a plausible trace at the wrong scale until `zig build test` runs. [#77](https://github.com/cboone/fosforo/issues/77) would close the half of that a text scan can reach. The other half, `TraceUniforms` layout drift, needs a readback: [#51](https://github.com/cboone/fosforo/issues/51) has landed and built one, and it still does not cover a *reloaded* shader, since `smoke-trace` measures the embedded copy and nothing reloads during a trace run.

**A build-time test comparing the embedded copy to the file was considered and refused.** They agree by construction: `@embedFile` resolves through `build.zig`'s anonymous import, so the compiler records a cache dependency and an edited shader rebuilds the test binary before it runs. The only way to write the test is as a runtime one, which would make `zig build test` read the filesystem, would fail on any machine where the baked path is stale, and would fail if the shader were saved while the tests ran, which is the normal state of the workflow it is for.
