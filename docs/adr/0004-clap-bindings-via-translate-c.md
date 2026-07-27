# 0004. CLAP bindings via translate-c over normalized headers

**Status:** Accepted

## Context

Reaching the CLAP C API from Zig has three candidate paths. The obvious one fails on inspection.

**Rejected: `clap-zig-bindings`.** The design brainstorm called this "the cleanest binding path." Direct examination shows it is not viable:

- It is **LGPLv3**. Zig module dependencies are compiled in statically, so this is an LGPL static-linking situation, carrying relinking obligations that are inappropriate for a plugin binary.
- It covers CLAP **1.2.2**. Current CLAP is **1.2.10**.
- It **does not compile on Zig 0.16**. `zig build test` fails on the removed `std.testing.refAllDeclsRecursive`.

**Rejected: hand-written bindings.** Full control and idiomatic types, but every `extern struct` is an ABI contract with the host, and a single wrong field offset is a crash in someone else's process rather than a compile error. The maintenance burden recurs on every CLAP release.

**Chosen: `translate-c`.** Always in sync with the vendored header, correctness guaranteed by the compiler, zero hand-maintenance. `@cImport` is deprecated in 0.16 in favour of `b.addTranslateC()` in the build system.

## Decision

Vendor the CLAP headers at a pinned version and generate bindings with `b.addTranslateC()`.

## Consequences

**Zig 0.16's `translate-c` has a `#pragma once` bug that must be worked around.** CLAP's headers reach each other through relative parent includes (`#include "../plugin.h"` from within `ext/`), so the same file is seen as both `clap/version.h` and `clap/factory/../version.h`. Clang deduplicates these by file identity; Zig's implementation does not, producing 161 redefinition errors. Plain `clang -fsyntax-only` over the same headers is clean, which localizes the fault.

Two workarounds were tried. The first rewrote the vendored headers so no aliased path could occur, which works but needs a custom tool and mutates a pinned dependency.

The adopted workaround is simpler: **run the headers through clang's preprocessor first**, then hand the result to `translate-c`. Clang deduplicates correctly, so the preprocessed output is a single translation unit with no includes left to alias. `zig cc` ships with Zig, so this adds no external dependency and needs no tool of our own.

The cost is that object-like macros are consumed rather than translated, which loses roughly 47 `#define` constants. What survives was checked rather than assumed: `CLAP_VERSION` is a `static const` and comes through fully populated at 1.2.10, all 38 extension id strings survive as statics, and `CLAP_INVALID_ID`, `CLAP_NAME_SIZE`, and `CLAP_PATH_SIZE` resolve to concrete values. Only the version component macros are genuinely lost, and `src/clap/c.zig` restates them with a test asserting they equal the surviving `CLAP_VERSION` struct, so drift is caught rather than trusted.

**Toolchain-generated names are not stable and must be guarded.** The anonymous union in `clap_window` translates to a field named `unnamed_0` of type `union_unnamed_9`. Nothing guarantees those names or the surrounding layout across Zig versions. Every struct crossing the ABI therefore gets comptime `@sizeOf` and `@offsetOf` assertions, so drift becomes a compile error rather than a crash in a host.

**Ergonomics are deferred, not abandoned.** `translate-c` output is C-shaped (`[*c]` pointers, `unnamed_0`). A thin idiomatic Zig layer sits over it where it pays, notably the entry, factory, and plugin glue. The translated module remains the single source of ABI truth.

Verified end to end: `export const clap_entry` emits the `_clap_entry` symbol, and Cocoa, Metal, QuartzCore, and CoreVideo all link.
