# Settle the convention for primitives Zig 0.16 moved behind `std.Io`

Addresses [issue #29](https://github.com/cboone/fosforo/issues/29).

## Context

Zig 0.16 moved three primitives this project needs behind an `Io` instance: `Mutex`, every clock, and `sleep`. Each site worked around it locally, and the three workarounds ended up in three files looking unrelated. They are one upstream change, and nothing in the tree recorded that.

Nothing was broken. Everything compiled, every check passed, and the leak and smoke results were clean. This is about coherence and about the next person.

It is also scheduled. `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md` folds #29 into phase 2 and says why: "The issue predicts a fourth local workaround will be added by whoever next needs a timer or a lock. Step 3's `deactivate` race is that moment, so the convention should be settled just before it rather than just after." That is [#37](https://github.com/cboone/fosforo/issues/37), which is two issues away.

## The measurement that decided it

The plan originally recommended declaring the primitives against libc and recording that as the convention, on the grounds that a plugin could not afford an `Io`. `Threaded.io()` builds a vtable literal naming all 113 implementations, so every one is address-taken and none can be stripped, which reads as networking and process spawning linked into a plugin that wanted a clock.

That is true of the vtable and false of the binary. Measured against this tree:

<!-- prettier-ignore -->
| Measurement                            | Result                                              |
| -------------------------------------- | --------------------------------------------------- |
| Debug `.clap`, before (libc clock)     | 2,118,064 bytes, **325 `Threaded` symbols already** |
| Debug `.clap`, with the `std.Io` clock | 2,117,936 bytes, same symbols. Delta **-128**       |
| Release `.clap`, either way            | 119,008 bytes, byte-identical                       |
| Release `.clap`, `nm -u` clock import  | **None**, in both versions                          |
| Harness, `usleep` to `Io.sleep`        | +384 bytes, 0%                                      |

Two causes, both verified rather than inferred:

- `std.debug.print` at `src/clap/log.zig:110`, the debug-only `stderr` mirror, already links the whole of `Io/Threaded.zig` into every debug build, networking address converters included. The plugin had been carrying it since before this issue existed.
- `monotonicNanos` is reached only from `Editor.report`, which is debug-only, so release builds strip the function along with its caller. That is why the release comparison shows no clock import in either version.

The cost the first recommendation was avoiding does not exist, so the recommendation changed. Two constraints from the same investigation are not about cost and did survive: `Threaded.init` calls `posix.sigaction` on `SIG.IO` and `SIG.PIPE`, which in a plugin replaces the host's handlers; and `std.Io.Semaphore` offers no try-wait.

Everything else checked against Zig 0.16.0, for the record:

<!-- prettier-ignore -->
| Claim                                          | Result                                                               |
| ---------------------------------------------- | -------------------------------------------------------------------- |
| `std.time` still has clocks                    | No. Constants only, no `Timer`, no `nanoTimestamp`                   |
| `std.Thread` still has `Mutex` or `sleep`      | No. `spawn` and `yield` survive, which is why `Gate.close` compiles  |
| `Io.VTable` function-pointer count             | 113                                                                  |
| `Io.Semaphore` has a try-wait                  | No. `wait` and `waitUncancelable` only, both to `futexWait`          |
| `Clock.awake` on macOS                         | `CLOCK_UPTIME_RAW`, the clock `monotonicNanos` already read          |
| `Io.sleep` on macOS                            | `nanosleep`. Darwin has no `clock_nanosleep`, so `sleepPosix` is out |
| `Syscall.start()` off a runtime-spawned thread | Returns `.{ .thread = null }`, so cancellation cannot fire           |
| `clock_gettime_nsec_np` availability           | `__OSX_AVAILABLE(10.12)`, below the 11.0 target                      |
| `usleep` availability                          | No annotation at all                                                 |

## The decision

Adopt `std.Io` through one `Threaded` instance in `src/platform/io.zig`, reached by `io.get()`. `init_single_threaded` is the only permitted constructor.

Callers stay where their reason is legible: the clock next to the render loop it paces, sleeping in the harness that waits. Only the construction is centralised.

`Gate` and the libdispatch semaphore are recorded as **not** `std.Io` cases, at the source as well as in the ADR, so the convention is reachable from either direction and cannot be over-applied.

## Work

1. **`src/platform/io.zig`** (new). Holds `var backend: std.Io.Threaded = .init_single_threaded` and `pub fn get() std.Io`. Carries the `Threaded.init` landmine and the thread-safety argument for sharing one instance.
1. **`src/platform/displaylink.zig`**. Delete `clock_uptime_raw` and `clock_gettime_nsec_np`; `monotonicNanos` becomes `@intCast(std.Io.Clock.awake.now(io.get()).nanoseconds)`.
1. **`src/smoke.zig`**. Delete `usleep`; add `sleepFor`, which calls `io.get().sleep(duration, .awake)`. Two call sites become `try sleepFor(.fromMilliseconds(50))` and `try sleepFor(.fromMicroseconds(frame_poll_us))`.
1. **`src/clap/gui.zig`**. Correct the `Gate` doc comment. Its stated reason, that Zig 0.16 has no mutex not wanting an `Io`, is no longer true now that one exists. The real reasons are the check-then-enter race and `Io.Mutex`'s contended path calling `futexWait` inside a gate `Editor.tick` holds.
1. **`src/gpu/metal/renderer.zig`**. Record that the libdispatch semaphore is not an ADR 0015 case and that `Io.Semaphore` could not replace it, having no try-wait.
1. **`docs/adr/0015-adopt-std-io-single-instance.md`** (new), **`docs/adr/README.md`** (one row), **`AGENTS.md`** (one non-negotiable, one gotcha).

## Files

<!-- prettier-ignore -->
| File                                            | Change                                             |
| ----------------------------------------------- | -------------------------------------------------- |
| `src/platform/io.zig`                           | New. The one `Io` instance                         |
| `src/platform/displaylink.zig`                  | libc clock removed, reads `io.get()`               |
| `src/smoke.zig`                                 | `usleep` removed, `sleepFor` added, two call sites |
| `src/clap/gui.zig`                              | `Gate` doc comment corrected                       |
| `src/gpu/metal/renderer.zig`                    | libdispatch doc comment, the distinction           |
| `docs/adr/0015-adopt-std-io-single-instance.md` | New. The decision                                  |
| `docs/adr/README.md`                            | One table row, no re-padding needed                |
| `AGENTS.md`                                     | One non-negotiable bullet, one gotcha bullet       |

## Verification

Run and recorded under Results below.

```bash
zig fmt --check build.zig src/
zig build test
zig build smoke-gpu                         # links Threaded at the 11.0 target
zig build smoke-appkit                      # exercises both sleep sites and the clock
zig build smoke-leaks                       # 400 cycles, judged by scripts/smoke-leak-check
markdownlint-cli2
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
```

Containment checks, which are the ones that can fail silently. Use plain `grep` rather than `git grep`, because a new untracked file is invisible to the latter and that is exactly how this check would report a false pass:

```bash
grep -rn "Io\.Threaded" src/         # expect one hit, src/platform/io.zig
grep -rn "Threaded\.init\b" src/     # expect doc-comment warnings only
grep -rn 'extern "c"' src/ | wc -l   # expect 11, down from 13
```

Size, against `main`:

```bash
zig build --release=fast && stat -f%z zig-out/Fosforo.clap/Contents/MacOS/Fosforo
```

## Results

<!-- prettier-ignore -->
| Check                            | Result                                             |
| -------------------------------- | -------------------------------------------------- |
| `zig fmt --check`                | Clean                                              |
| `zig build test`                 | Pass                                               |
| `zig build smoke-gpu`            | Pass, device acquired, shaders compiled            |
| `zig build smoke-appkit`         | Pass, 10 open and close cycles clean               |
| `zig build smoke-leaks`          | Pass                                               |
| `markdownlint-cli2`              | Clean                                              |
| `shfmt` and `shellcheck`         | Clean                                              |
| Release `.clap` size             | 119,008 bytes, unchanged from `main`               |
| Debug `.clap` size               | 2,118,016 bytes, -48 from `main`                   |
| `Io.Threaded` construction sites | One, `src/platform/io.zig`, `init_single_threaded` |
| `extern "c"` count in `src/`     | 11, down from 13                                   |

## Known limits, stated rather than left to be discovered

- **The harness's sleep changed from `usleep` to `nanosleep`.** Same granularity for a 1 ms poll, but `sleepNanosleep` retries on `EINTR` where the bare `usleep` did not. An improvement rather than a regression, and worth knowing if a future harness hang is ever traced here.
- **The plugin's zero cost rests on something incidental.** `Io/Threaded` is in debug builds because `std.debug.print` puts it there, not because this decision did. If `clap/log.zig`'s `stderr` mirror ever goes, the debug binary will start paying for `Io` deliberately. Release builds are unaffected either way, since they strip both.
- **This settles the convention, not the fourth case.** [#37](https://github.com/cboone/fosforo/issues/37) still has to decide what its `deactivate` race uses. The ADR tells it where to look and what it may not do; it does not pre-decide the answer.
- **The `Cancelable` error can never fire, and the code still propagates it.** That rests on `Threaded.Thread.current` being set only for runtime-spawned threads. If a future Zig sets it more widely, `try sleepFor(...)` becomes a real error path in the harness rather than a formality.

## Out of scope

- **A `src/platform/libc.zig` module.** After this there is no libc shim caused by `std.Io` to put in one. `Gate` and `dispatch_semaphore_*` would not have moved into it, because neither stands in for something `std` took away.
- **Replacing `Gate` or the libdispatch semaphore.** Both were measured against `std.Io` and neither has a viable replacement. Recorded in the ADR so it is not re-argued.
- **Any enforcement mechanism** beyond the `grep` checks above. A build-time assertion on `Io` construction sites is conceivable and is not worth its complexity against three greps.
- **`std.process.Init.Minimal` in `src/smoke.zig`.** Also a 0.16 migration, already absorbed rather than worked around.

## Commits

1. `refactor: adopt std.Io through one single-threaded instance (#29)` - `src/platform/io.zig`, `displaylink.zig`, `smoke.zig`
1. `docs: record that Gate and the frame semaphore are not std.Io cases (#29)` - `gui.zig`, `renderer.zig`
1. `docs: record the std.Io decision as ADR 0015 (#29)` - the ADR, the README row, `AGENTS.md`

Leave issue #29 labelled `in progress` until the pull request merges.
