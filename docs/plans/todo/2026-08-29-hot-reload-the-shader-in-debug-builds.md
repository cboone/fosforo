# Hot-reload the shader in debug builds

Addresses [#61](https://github.com/cboone/fosforo/issues/61).

## Context

Phase 3 has five issues of shader iteration left ([#56](https://github.com/cboone/fosforo/issues/56), [#57](https://github.com/cboone/fosforo/issues/57), [#58](https://github.com/cboone/fosforo/issues/58), [#59](https://github.com/cboone/fosforo/issues/59), [#60](https://github.com/cboone/fosforo/issues/60)), and the loop for each tweak is edit, `zig build install-plugins`, restart REAPER, reload the project, reopen the editor. This issue is pulled forward from its filed position at step 9 for exactly that reason: it improves nothing about the picture and a great deal about arriving at it, and its value is proportional to how much shader iteration comes after it.

It is not a new decision. [ADR 0009](../../adr/0009-runtime-shader-compilation.md) chose runtime MSL compilation partly to make this possible and its Consequences already say, verbatim, "Debug builds reload from disk; release builds use the embedded source." What follows discharges a recorded consequence rather than making a call, which is why it amends that ADR instead of adding one.

**It also sets a precedent one later issue is waiting on.** [#59](https://github.com/cboone/fosforo/issues/59) defers the same question in the same words: "The render thread is the obvious home, but the same constraint applies in weaker form, since `Editor.tick` holds the gate across its whole body and anything unbounded there becomes a wait the host's main thread can take when an editor closes." #59 multiplies a 960-sample window into 3840 segments, and [#62](https://github.com/cboone/fosforo/issues/62) adds decimation between `Ring.read` and `upload`. The tick is about to have less headroom, not more. Handing finished work into the top of a tick through a mailbox is the shape #59 will reach for if it decides its upsampling cannot run inline; establishing that machinery here makes it available.

The intended outcome: saving `shaders/scope.metal` changes the picture in a running host within about a quarter second, a broken shader is refused without stopping the render loop, and a release build carries neither the watcher nor a path into anybody's worktree.

## Findings that shaped the design

Verified against the pinned Zig 0.16.0 at `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std` and against this tree, not inherited from the issue.

### The issue's own framing needs three corrections

**`Renderer.init` cannot spawn the watcher.** It returns a `Renderer` **by value**: the seam pins that signature at `src/gpu/iface.zig:264` and `src/clap/gui.zig:533` copies the result into a field. A thread handed `&self` from inside `init` would hold the address of a temporary that is about to be copied away. The watcher therefore starts lazily on the first `Renderer.frame`, which is the earliest moment the object has the address the render thread will keep using. Two wanted properties fall out: an editor created and never shown never ticks, so it never watches; and the spawn lands once inside a frame budget rather than on `set_parent`, where the host is already waiting on a compile.

**The mailbox cannot be `Pending`'s single atomic swap.** `Pending` (`src/clap/gui.zig:128-189`) is one store and one swap **only because its whole payload is the `u64`**. A `Pipelines` is three object pointers. So the payload sits beside a state word, and the consumer must copy it **before** it empties the slot, which is the reverse of `Pending.take`'s order at `src/clap/gui.zig:180`. Imitating the neighbour is the single likeliest way to get this wrong, and the symptom is three pointers drawn from two different compiles rather than a crash.

**The compile cost the issue rests on has never been measured.** `AGENTS.md` records that `newLibraryWithSource:` compiles out of process in `MTLCompilerService.xpc`, and `src/gpu/metal/renderer.zig:273-277` calls it the most expensive thing `init` does, but no figure exists anywhere in the repository. It is the first thing this branch measures.

### What Zig 0.16 actually offers

| Wanted                     | Does not exist                                                  | Use instead                                                         |
| -------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------- |
| An interruptible poll wait | `std.Thread.Futex`, `std.Thread.ResetEvent`, `std.Thread.Mutex` | `std.Io.futexWaitTimeout` / `futexWake` (`std/Io.zig:1558`, `1576`) |
| Reading an env var         | `std.posix.getenv`, `std.process.getEnvVarOwned`                | `std.c.getenv` (`std/c.zig:10719`), which `link_libc` enables       |
| Writing an env var         | `std.c.setenv` (absent from all of `std`)                       | `extern "c" fn setenv`, declared in `src/smoke.zig`                 |
| Reading a file             | `std.fs` file I/O (`std/fs.zig` is six re-exports)              | `std.Io.Dir.cwd().statFile` / `.readFile`, through `io.get()`       |

Three consequences follow.

**The poll wait is ADR 0015's own instrument, not an exemption from it.** `std/Thread.zig` in 0.16 declares only `spawn`, `join`, `detach`, `yield`, `setName`, `getName` and `getCpuCount`; everything else moved onto `std.Io`. Reaching `futexWaitTimeout` through `io.get()` is [ADR 0015](../../adr/0015-adopt-std-io-single-instance.md) being followed.

**File I/O on the shared instance is safe from a spawned thread**, on the argument `src/platform/io.zig:26-30` already makes for `sleep`. Confirmed in the pinned source rather than assumed: `fileStatPosix` discards its userdata (`std/Io/Threaded.zig:3853-3854`) and reaches the syscall through `Syscall.start()`, which returns `.{ .thread = null }` whenever `Threaded.Thread.current` is unset (`Threaded.zig:1347-1348`), and only threads the runtime spawns ever set it. **That file's header sentence, "Two of those this project needs and takes from here", becomes three.**

**A plugin has no `main`, so `std.process.Init` is unreachable from the shipping half.** `Environ`, `Args`, the default `gpa` and the default `Io` are all available to `src/smoke.zig` and `src/ring_race.zig` and to nothing else here. That is why `std.c.getenv` is the only option rather than the convenient one.

### The build path is easier to get subtly wrong than it looks

- **`b.pathFromRoot` carries a "code smell" docstring** (`std/Build.zig:1767-1769`) and hides an `orelse "."`. `LazyPath.getPath` through `getPath3` are all deprecated in favour of a make-phase `getPath4`. Use `b.pathResolve` directly.
- **`std.fs.path.resolve` does not make a relative path absolute** in 0.16 (`std/fs/path.zig:872-874`), so a path derived from the build root is absolute only if the build root is. A relative path baked into a plugin resolves against the **DAW's** working directory, which is right only when REAPER happened to be launched from a worktree. Gate on `std.fs.path.isAbsolute`.
- **`b.build_root.path == null` means "the build root is the working directory"**, not "there is no build root" (`std/Build/Cache/Directory.zig:11-13`; the build runner `fatal`s without one). So `gitProvenance`'s `orelse return .unknown` at `build.zig:127` guards a different thing than the tarball case, which is actually handled by `runAllowFail` failing. Do not inherit the wrong reason for the `orelse`.

### Two gates, and neither substitutes for the other

`zig build test` is a Debug build, which `AGENTS.md:241` already records. So `builtin.mode == .Debug` alone would put filesystem reads inside the hermetic test path ADR 0009 exists to protect.

| Gate                                          | Guarantees                                                             |
| --------------------------------------------- | ---------------------------------------------------------------------- |
| `build.zig`: emit the path only when `.Debug` | No release bundle carries an absolute path into somebody's source tree |
| `builtin.mode == .Debug and !builtin.is_test` | No code reads it, and `zig build test` stays hermetic                  |

The `build.zig` gate cannot make code disappear; the source gate cannot keep a string out of a shipped binary except as a claim about the optimizer, and `src/build_info.zig:52-58` already refuses that standard for `marker`. Both, with CI asserting the first.

### Three things that need no work

- **A pipeline state needs no live counter.** `src/gpu/metal/renderer.zig:377-380` and the instrument table in `AGENTS.md` both record that `leaks` **can** see one, unlike an `MTLBuffer` or an `MTLTexture`. ADR 0013's "measure with a planted leak before assuming coverage" rule is already discharged for this resource class, and a swap that leaked its outgoing set is caught by `smoke-leaks` with no new instrument.
- **`validate-shaders` does not change.** It type-checks `shaders/scope.metal` and hot reload changes neither the file nor the question. `AGENTS.md:233` already records why it and `smoke-gpu` are not interchangeable.
- **No `timeout-minutes` changes.** The added smoke arms are fractions of a second against ceilings sitting at roughly 4x the slowest observed run. Stated rather than assumed, because `AGENTS.md:265` forbids copying a neighbour's value and the right action here is "measured, and no change".

### One thing that is genuinely lost, and must be documented

**Nothing validates a hot-reloaded shader's bindings.** The `bindingIndexAfter` tests (`renderer.zig:1501-1563`), the `TraceUniforms` layout test (`1742`), and the `measure-trace` constants test (`1611`) all read the **embedded** copy at comptime, and that is correct: a test about a file that can change between a build and a frame would say nothing. A file swapped in at runtime therefore gets `buildPipeline`'s missing-function check and nothing else. A moved `[[buffer(N)]]` draws a plausible trace at the wrong scale, silently, until `zig build test` runs.

## Design

### Where the source comes from

A new `src/gpu/metal/shader.zig`, below the seam so nothing above `src/gpu/iface.zig` learns a shader can come from a file. It names no Metal type, so `renderer.zig`'s claim to be the only file allowed to do so survives; the watcher, which does compile, stays in `renderer.zig`.

It owns `embedded` (today's `@embedFile`), the gate, path selection, the stamp, and an allocation-free read.

```zig
/// Whether this build reads the shader from a file at all.
///
/// `!builtin.is_test` is not belt and braces. A test binary is a Debug build, so
/// `builtin.mode` alone would put filesystem reads inside `zig build test`, which is
/// the hermetic path ADR 0009 exists to protect. `src/clap/log.zig:109` disables its
/// stderr mirror on exactly this pair.
pub const live = builtin.mode == .Debug and !builtin.is_test;

pub const path_env = "FOSFORO_SHADER_PATH";

/// Pure, so the ordering is testable without an environment, a build, or a filesystem.
pub fn choosePath(env: ?[]const u8, option: []const u8) ?[]const u8 {
    if (env) |p| if (p.len > 0 and std.fs.path.isAbsolute(p)) return p;
    if (option.len > 0 and std.fs.path.isAbsolute(option)) return option;
    return null;
}
```

Resolution order, and the fall-through rules that are not obvious:

| Case                                | Result                                                             |
| ----------------------------------- | ------------------------------------------------------------------ |
| `FOSFORO_SHADER_PATH` set, absolute | Wins. Existence is **not** checked here                            |
| Set but relative                    | Refused, falls through to the build option, and says which and why |
| Set but missing on disk             | Falls back to **the embedded copy**, never to the build option     |
| Unset or empty                      | The build option                                                   |
| Neither                             | The embedded copy, silently: this is every release build           |

The env pointer belongs to libc and a `setenv` anywhere in the host can free it, so it is read once, early, on the main thread, and copied into a fixed buffer.

Change detection is a three-field stamp, and the third field is load-bearing:

```zig
/// Three fields, not one, and the inode is the one that is easy to omit. Many editors
/// save by writing a temporary and renaming it over the target, so the path acquires a
/// **new** inode with a plausible mtime and an identical size. Watching mtime alone
/// misses a same-nanosecond rename; watching size alone misses every edit that does not
/// change the length. This is how a hot reloader appears to work and then quietly stops.
pub const Stamp = struct { mtime_ns: i96, size: u64, inode: std.Io.File.INode };
```

The read goes into a fixed 64 KiB buffer, so the reload path needs no allocator: `shaders/scope.metal` is 8,087 bytes today, and a test pins the headroom. `Io.Dir.readFile` documents that a returned length equal to the buffer's is ambiguous, so that case is refused as `error.ShaderTooLarge` rather than compiled as half a shader.

### The build option

`build.zig` gains `shader_source_path` as a file-scope constant beside `frameworks`, used at all three sites that name the file today (`build.zig:282`, `build.zig:455`, and the new one), plus:

```zig
fn debugShaderPath(b: *std.Build, optimize: std.builtin.OptimizeMode) []const u8 {
    if (optimize != .Debug) return "";

    const root = b.build_root.path orelse return "";
    if (!std.fs.path.isAbsolute(root)) return "";

    return b.pathResolve(&.{ root, shader_source_path });
}
```

Resolved once in `build()` and carried on `Core` beside `provenance`, for that field's reason: four artifacts that must not disagree. The option is added in `Core.module` immediately after `git_dirty` (`build.zig:264`), not sentinel-terminated, since it is opened rather than passed across the ABI.

Cache-key cost, against the warning already at `build.zig:257-260`: branch, commit and dirty change per commit and per edit, while this changes only when a worktree moves. It costs one extra full rebuild after a `git worktree move`, and it stops two worktrees at the same commit sharing a cache entry.

### The watcher

Debug-only, one per `Renderer`, owned by it, spawned lazily on the first `frame` and joined in `deinit`.

```text
Watcher thread                      Render thread (Editor.tick -> Renderer.frame)
------------------------------      ---------------------------------------------
park 250 ms (futexWaitTimeout)
mailbox vacant?  ------ no -------> (skip, do not advance the stamp)
stat -> changed?
read into a fixed buffer
buildPipelinesFromSource
  (XPC to MTLCompilerService)
publish ----------> [ mailbox ] ---> take (copy, then empty)
                                     swap self.pipelines
                                     release the outgoing set
                                     ...then the frame as it is today
```

`park` uses `io.get().futexWaitTimeout` with the **stop flag as the futex word**, which is what makes the wake race-free rather than lucky: the kernel re-checks the word under its own lock before parking, so a stop that lands between the last check and the call returns immediately instead of sleeping the interval out. Split into a `bool` and a separate word and the classic missed wakeup is back, at a quarter second on the host's main thread every time an editor closes.

`stop` stores the flag `.release`, then wakes, then joins. Flag before wake, never after.

The watcher also needs its own `objc.AutoreleasePool` per poll: `platform.nsString` returns an autoreleased object (`src/platform/objc.zig:33-41`) and a spawned thread has no pool and no run loop to drain one. `Renderer.init` makes exactly this point at `renderer.zig:493-496`.

**Polling rather than a dispatch source**, deliberately: a `dispatch_source_t` on a file descriptor watches a vnode, and the save-by-rename case the stamp exists for is precisely where the watched vnode stops being the path.

### The mailbox

Two states. Only the watcher does empty to full; only the render thread does full to empty.

```zig
fn take(self: *Mailbox) ?Pipelines {
    if (self.state.load(.acquire) != .full) return null;
    const taken = self.staged;          // copy first
    self.state.store(.empty, .release); // then empty
    return taken;
}
```

The order of those two lines is the whole design. `Pending.take` at `src/clap/gui.zig:180` does the opposite, correctly, because its payload is the word; doing it here would let the watcher begin overwriting `staged` while the render thread is still reading it.

`vacant()` is checked **before** the compile rather than after, so a hidden editor costs four `fstatat` calls a second and zero XPC round trips. A skipped poll does not advance the stamp, so nothing is lost. The consequence worth naming: this is first-write-wins-then-converge rather than `Pending`'s last-write-wins. Five saves with the editor hidden show edit 1 for one poll interval when it reopens, then edit 5. Nobody is looking during the hidden period and it self-corrects.

### The swap point

At the very top of `Renderer.frame`, after the autorelease pool and **above both** the `.no_accumulation` return (`renderer.zig:785`) and the semaphore try-wait (`792`). Two different mistakes:

- **Below `.no_accumulation`** wedges reload entirely. `src/gpu/iface.zig:175-183` records that this is the one skip that **persists**, lasting until a resize succeeds. The watcher would sit on a full slot refusing to recompile and every later edit would do nothing, silently.
- **Below the wait** gates the fix on the problem stopping. `.no_frame_slot` is what a loaded GPU returns, and a run of them is exactly when someone is editing the shader that caused it. The swap uses no slot and touches no per-frame resource.

`frame` then takes the set into a local beside `source`/`target` (`renderer.zig:828-829`) and binds from it at all three sites, so "one frame encodes with one library" is structural rather than true by inspection.

**Releasing the outgoing set immediately on the render thread is safe**, on the rule `replaceAccumulation` already leans on at `renderer.zig:687-695`: a command buffer created through `-[MTLCommandQueue commandBuffer]` retains every resource it references until it completes. The release drops this object's claim and not the GPU's. Worth one sentence in the docstring naming what would break it, because `MTLIndirectCommandBuffer` and argument-buffer-resident pipeline states do not take that reference for you.

### `buildPipelines` keeps its signature

Wrap it rather than adding a parameter, so `init` (`renderer.zig:521`) and `probe` (`610`) are byte-for-byte unchanged and `shader_source` stays named once:

```zig
fn buildPipelines(device: objc.Object, diags: *iface.Diagnostics) iface.Error!Pipelines {
    return buildPipelinesFromSource(device, shader_source, diags);
}
```

ADR 0013's property, that `probe` **shares** `buildPipelines` with `init` rather than paraphrasing it, then survives by construction instead of by two call sites agreeing to pass the same constant.

### Failure handling

All-or-nothing already: `buildPipelinesFromSource` releases what it took through `errdefer` (`renderer.zig:1226-1233`), so nothing partial exists. On failure the mailbox stays empty, `frame` finds nothing to drain, and **the editor keeps rendering the last shader that compiled**, which is `replaceAccumulation`'s fail-soft shape.

The diagnostic already carries the `NSError`'s `localizedDescription` through `describe` (`renderer.zig:1450-1458`), so it names a line and a mistake. It goes to `std.debug.print` from the watcher thread, gated on the same `live` constant. That is right here for reasons that do not apply elsewhere: the watcher is not the audio thread, not the render thread, and not the host's main thread, so it may lock and syscall; and it is already this project's debug channel, which `AGENTS.md:211` tells a developer to read by launching the host from a terminal.

**The stamp advances on failure too.** Without that, a broken file prints four identical diagnostics a second forever; with it, it prints once per save and recovers when the file is fixed. The path-missing case gets the same one-shot treatment, which is the issue's own "saying so once is probably better".

## Work

Eight commits, each leaving `zig build`, `zig build test`, `zig fmt --check build.zig src/`, `shfmt`/`shellcheck`, `typos` and `ruff` green.

1. **`chore: measure what compiling the shader actually costs (#61)`** — time `newLibraryWithSource:` plus the three `newRenderPipelineStateWithDescriptor:` calls, record the figure in `AGENTS.md` beside the XPC bullet. Replaces this issue's central unmeasured assumption with a number, and is what the poll interval and the `deinit` join bound get quoted against.
1. **`build: name the shader once and hand its absolute path to debug builds (#61)`** — `build.zig` only: the `shader_source_path` constant at all three sites, `debugShaderPath`, `Core.shader_path`, the `addOption` call and its cache-key comment. No reader yet, said so in the body.
1. **`feat: choose the shader source between the file and the binary (#61)`** — new `src/gpu/metal/shader.zig` with `embedded`, `live`, `choosePath`, `resolvePath`, `Stamp`/`changed`/`stamp`, the fixed-buffer read, and its unit tests. `renderer.zig:28` becomes `const shader_source = shader.embedded;` with a comment narrowing what the tests below it claim. **No test in `renderer.zig` moves.** `src/platform/io.zig`'s header goes from two primitives to three.
1. **`feat: compile from the file a debug build was built from (#61)`** — `buildPipelinesFromSource` and its wrapper; `init` and `probe` unchanged; the fallback rule and its once-per-open message; `iface.ShaderStats` and `Renderer.shaderStats()` with its `assertSignature` line beside the two live-resource counters at `iface.zig:287-288`.
1. **`feat: recompile and swap the pipelines when the file changes (#61)`** — the watcher, the mailbox, the lazy start, the swap and the outgoing release, the `deinit` join and slot drain.
1. **`test: assert the fallback path in the GPU smoke half (#61)`** — the `setenv` extern, the `$TMPDIR` fixture with a write-then-stat guard and a `defer` cleanup, the four `gpu` arms, and the not-compiled-in skip.
1. **`test: assert a live swap, a refusal, and a recovery in the AppKit half (#61)`** — `hotReloadPhase`, placed before the cycle loop.
1. **`docs: record what hot reload costs and what the harness now asserts (#61)`** — the two ADR amendments, the `AGENTS.md` gotchas, the Development block line, the current-state paragraph, `CHANGELOG.md`.

### Files

| File                         | Change                                                                    |
| ---------------------------- | ------------------------------------------------------------------------- |
| `src/gpu/metal/shader.zig`   | **New.** Source selection, the stamp, the read. Names no Metal type       |
| `src/gpu/metal/renderer.zig` | The watcher, the mailbox, the swap in `frame`, the split `buildPipelines` |
| `src/gpu/iface.zig`          | `ShaderStats` and one `assertSignature` line                              |
| `src/platform/io.zig`        | Header prose: two primitives becomes three                                |
| `build.zig`                  | The named constant, `debugShaderPath`, `Core.shader_path`, the option     |
| `src/smoke.zig`              | The `setenv` extern, the fixtures, the arms in both halves                |
| `.github/workflows/ci.yml`   | One step in `clap-wrapper`, the only job that builds `--release=fast`     |
| `docs/adr/0009-*`, `0013-*`  | Amendment sections in the appended form 0013 already uses three times     |
| `AGENTS.md`                  | Gotchas, the Development block, the current-state paragraph               |

### Reused rather than written

- `buildPipeline` / `releasePipelines` / `describe` (`renderer.zig:1248`, `1242`, `1448`) unchanged; `releasePipelines` stays the one release site, which every abandoning path must reach.
- `replaceAccumulation` (`renderer.zig:686-713`) as the model for a render-thread, fail-soft, release-then-rebuild operation with its own local `iface.Diagnostics`.
- `Pending` (`gui.zig:128-189`) as the shape and the place the ordering reasoning already lives, with the copy-order difference called out at the source.
- `Gate` (`gui.zig:887-926`) untouched; the point of the design is that its bound does not move.
- `io.get()` (`platform/io.zig:40`) for the futex wait, the wake, and every file operation.
- `gitProvenance` (`build.zig:126-152`) as the model for a build-time fact that degrades rather than failing.
- `scripts/smoke-leak-check`'s `mktemp -t` plus `trap … EXIT` as the precedent for where a fixture lives.

## Verification

### Automated

`zig build test` gains pure tests in `shader.zig`: env beats the build option, an empty value is not a path, a relative path is refused rather than resolved against the host's directory, a change is any of three fields (including same mtime and same size through a rename), the embedded shader fits the buffer with room to spare, and `!live` under test, which fails the moment `!builtin.is_test` is dropped.

`zig build smoke-gpu` (CI-required, no window) asserts the invariant that can ruin a day: **a debug build opens its editor whatever is on disk.**

| Fixture                                | Assertion                                           |
| -------------------------------------- | --------------------------------------------------- |
| A byte-identical copy in `$TMPDIR`     | `probe` succeeds; `disk_reads` +1; `fallbacks` flat |
| A path that does not exist             | `probe` **succeeds**; `fallbacks` +1                |
| A file holding `this is not metal`     | `probe` **succeeds**; `fallbacks` +1                |
| A copy with `resolve_fragment` renamed | `probe` **succeeds**; `fallbacks` +1                |

The last row is what proves the new bytes reached the compiler: only the edited file produces `buildPipeline`'s missing-function diagnostic, which a counter alone cannot distinguish from recompiling the embedded copy.

`zig build smoke-appkit` gains `hotReloadPhase`, run **once per process** before the cycle loop, so `smoke-leaks -Dleak-cycles=400` does not pay for 1,200 out-of-process compiles and the existing zero-live-resource assertions cover it for free.

| Arm                   | Fixture                                 | Assertion                                                          |
| --------------------- | --------------------------------------- | ------------------------------------------------------------------ |
| A good edit           | embedded plus a comment                 | `reloads` +1; frames advanced by ≥2 across the swap; uploads moved |
| A broken edit         | `this is not metal`                     | `rejected` +1; `reloads` flat; frames still advancing              |
| Compiles but is wrong | `resolve_fragment` renamed              | `rejected` +1; the `clap.log` line names the missing functions     |
| Recovery              | a different good edit, **equal length** | `reloads` +2                                                       |

Arm four's equal length is the positive control that turns "the detector compares size only" from an assumption into a planted defect that fails.

**The vacuity guard:** `zig build smoke --release=fast` is legal, and there `live == false`. The harness must say `skipping: this build has no shader reload` and carry it into the summary, never pass silently. That is ADR 0013's "an absence has to be told apart from an instrument that did not run", applied to a build mode.

### Planted defects, including the two that pass

| Plant                                        | Result                                                   |
| -------------------------------------------- | -------------------------------------------------------- |
| The watcher never starts                     | `ShaderNeverReloaded`, arm 1                             |
| The watcher fires once and stops             | `ShaderNeverReloaded`, arm 4                             |
| Detection compares size only                 | Passes arm 1, fails arm 4                                |
| `choosePath` prefers the option over the env | The fixture is never watched; `ShaderNeverReloaded`      |
| `take` empties before copying, plus a spin   | Validation failure or a crash under a hammer-save script |
| The `deinit` slot drain removed              | Three `AGX…RenderPipelineState` objects in `smoke-leaks` |
| The outgoing set released before the swap    | Crash or assert under `MTL_DEBUG_LAYER=1`                |
| The watcher writes `pipelines` and releases  | Crash inside `frame`'s encode within seconds             |
| `park` replaced with a 10 s `sleep`          | The host's main thread beachballs on editor close        |
| `futexWake` deleted from `stop`              | Close still completes, stalled up to 250 ms              |
| `!builtin.is_test` dropped                   | The `!live` test fails                                   |
| The `optimize == .Debug` gate dropped        | The CI grep fails                                        |
| **The compile moved onto the render thread** | **Passes.** A stall is invisible to a frame counter      |
| **A reload with a moved `[[buffer(N)]]`**    | **Passes.** Nothing validates bindings at runtime        |

The last two are the honest limits and belong in the ADR 0013 amendment rather than being glossed.

### CI

One step in the `clap-wrapper` job, the only one that builds `--release=fast`: assert the release binary carries **no** source path, with the `fosforo-build:` provenance marker grepped first as a positive control, on `scripts/assert-adhoc-signature`'s precedent that a negative assertion proves nothing until the file is known readable. It must not go in `Build` or `clap-validator`, which build Debug and where the path is present and correct.

### By hand, in a host

The half no harness reaches. `install-plugins` is not needed: `CLAP_PATH` takes the CLAP out of the shared folder entirely.

```bash
zig build
FOSFORO_SHADER_PATH="$PWD/shaders/scope.metal" CLAP_PATH="$PWD/zig-out" \
  /Applications/REAPER.app/Contents/MacOS/REAPER
```

Then, with a 100 Hz sine playing from `~/Music/fosforo-test-tones/`:

1. Change `trace_fragment`'s literal, save, and confirm the trace changes colour without touching the host. Confirm the accumulation is **not** cleared, so the old colour fades rather than vanishing.
1. Repeat with the transport stopped and the plugin deactivated, so the trace draw is skipped. The swap must still happen, which proves the drain is not entangled with the frame's content.
1. Introduce a syntax error, save. The picture must keep rendering the previous shader, exactly one diagnostic must appear naming the MSL line, and nothing further until the next save. Fix it and confirm recovery with no restart.
1. Save, then close the editor within the poll interval, and confirm the close is not perceptibly delayed.
1. Hide the editor, save five distinguishable colours, show it. Confirm two compiles rather than five, and that the final picture is the fifth edit.
1. `git worktree move` the tree, relaunch without the env var: it must fall back to the embedded copy, say so once, and keep rendering.
1. Confirm `strings` on a `--release=fast` bundle finds no path from this worktree.

Re-measure the `smoke-leaks` baseline afterwards. The harness now spawns and joins a thread per reload phase, and `AGENTS.md`'s 288-leaks / 18,816-byte figure should be restated rather than assumed. The 1 MiB byte bound has ample headroom either way.

## Out of scope

Hot-reloading Zig, which the issue excludes. Validating a reloaded shader's binding indices at runtime, which is [#51](https://github.com/cboone/fosforo/issues/51)'s territory and needs a readback rather than a text scan. Any release-build reload path, which ADR 0009 rules out.
