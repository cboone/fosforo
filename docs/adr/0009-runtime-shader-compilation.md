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
