# 0003. Author CLAP once, project outward with clap-wrapper

**Status:** Accepted

## Context

The plugin must eventually load in Logic Pro, which loads **only** Audio Units. A raw `.clap` is invisible to it. The naive reading of that constraint is "author an Audio Unit," which would be a mistake.

The three candidate formats are not equivalent targets for a non-C++ language:

- **CLAP** is a plain C header, MIT licensed, with no SDK license agreement and no C++ in its contract. Any language with a C FFI implements it directly.
- **VST3** is not a C API at all. It is a COM-style C++ interface with vtable layout and reference counting baked into the binary contract, which any non-C++ language has to hand-reconstruct. This makes VST3 bindings the most fragile part of any non-C++ stack. The Zig framework Arbor's TODO on the subject reads "figure out if we can write a binding without getting a lawyer," which is a candid report from someone who hit the wall.
- **Audio Units** are C-callable at the entry point but sit atop a substantial pile of Core Audio and Objective-C plumbing.

## Decision

Author the plugin **once**, as a CLAP, and only as a CLAP. Use [clap-wrapper](https://github.com/free-audio/clap-wrapper) to project it into every other format.

## Consequences

The mental model that matters: clap-wrapper is not a port, a rewrite, or a second target to maintain. It is itself a small CLAP host wearing the costume of whatever format the outer host wants. An Audio Unit host loads the wrapper; the wrapper is handed the plugin's entry point and translates every interaction (parameters, audio buffers, GUI parent-window handoff, state save and load) in both directions. The plugin never knows it is not talking to a native CLAP host.

All the C++ (VST3) and Objective-C (AU) plumbing is absorbed by that project, written and maintained once, by someone else.

**The integration shape is the opposite of what might be assumed.** Verified by reading clap-wrapper's CMake: `make_clapfirst_plugins` takes an `IMPL_TARGET`, which is a **static library** exporting init, deinit, and get-factory functions, plus an `ENTRY_SOURCE`, which is a small C++ file constructing the entry struct. It then assembles every format including the `.clap` itself. So the Zig build produces a static archive, not a `.clap` dylib.

That inversion turns out to be an advantage. The static archive gets two consumers:

1. `zig build` links it into a `.clap` bundle directly, which REAPER loads natively. This is the day-to-day loop and never invokes CMake.
2. CMake and clap-wrapper link it into the AUv2 `.component` Logic needs, plus a standalone app.

A C++ build system therefore stays off the path where iteration speed matters.

**Limits of the technique.** The projection is only as complete as the feature mapping. A plugin leaning on CLAP-specific capabilities (polyphonic per-note modulation, the thread-pool extension) would find those degraded or absent in older formats. An analyzer is audio in, audio out, a Cocoa GUI, and a few parameters, which maps completely. This is a non-issue here but it is the general boundary.

**Development loop.** Develop against the raw CLAP, because a CLAP-native host loads it instantly and `clap-validator` tests it with no wrapper in the path, so what is being debugged is the clean thing. Run clap-wrapper to also emit the Audio Unit, validated with `auval`.
