# 0015. Adopt std.Io through one single-threaded instance

**Status:** Accepted

## Context

Zig 0.16 moved three primitives this project needs behind an `Io` instance: `Mutex`, every clock, and `sleep`. `std.time` is now constants only, and `std.Thread` keeps `spawn` and `yield` and nothing else this project was using. Each site that hit the wall answered it locally, and by the time [issue #29](https://github.com/cboone/fosforo/issues/29) was filed three workarounds sat in three files looking unrelated: a hand-rolled atomic word in `src/clap/gui.zig`, `clock_gettime_nsec_np` in `src/platform/displaylink.zig`, and `usleep` in `src/smoke.zig`. Each was defensible alone. None recorded that they shared a cause.

Three answers were available, and the choice turned on what `std.Io` actually costs rather than on how owning one feels:

- **Declare the primitives against libc, each beside its only caller.** Cheapest, honest that three sites is not yet a problem, and consistent with how `CVDisplayLink` and Metal's enums are already handled. Rejected because the cost it was avoiding turned out not to exist.
- **Collect the libc declarations into one module.** Rejected because it buys visibility at the price of separating each declaration from the caller whose doc comment explains it, and because two of the four local primitives are not libc shims at all and would not have moved into it.
- **Adopt `std.Io`.** Adopted, in the narrow form below.

The measurement that decided it, taken against Zig 0.16.0 and this tree rather than reasoned about. The concern was that `Threaded.io()` builds a vtable literal naming all 113 implementations, so every one is address-taken and none can be stripped, dragging networking, process spawning and kqueue into a plugin that wanted a clock. That is true of the vtable and false of the binary:

- The debug `.clap` **already** carried 325 `Io.Threaded` symbols before any adoption, because `std.debug.print` in `src/clap/log.zig` links the implementation for the debug-only `stderr` mirror.
- Adopting `std.Io` for the render meter's clock moved the debug `.clap` by **-128 bytes** and added no symbol.
- The release `.clap` was **byte-identical**, because `monotonicNanos` is reached only from `Editor.report`, which is debug-only, so the function is stripped along with its caller. `nm -u` shows no clock import in either version.

Two constraints from the same investigation are not about cost and do not go away:

- `Threaded.init` calls `posix.sigaction` on `SIG.IO` and `SIG.PIPE`. A plugin is loaded into the host's address space, so it would replace REAPER's or Logic's handlers rather than install its own.
- `std.Io.Semaphore` has `wait` and `waitUncancelable` and no try-wait, both routed through `Io.Mutex` and `Io.Condition` to `futexWait`.

## Decision

Adopt `std.Io`, through a single `Threaded` instance constructed in `src/platform/io.zig` and reached by `io.get()`.

**`init_single_threaded` is the only permitted constructor.** `Threaded.init` is never called anywhere in this repository, for the signal-handler reason above.

Callers still live where their reason is legible: the clock stays next to the render loop it paces, and sleeping stays in the harness that waits. What is centralised is the construction, not the use.

## Consequences

**Two `extern "c"` declarations are gone and nothing replaced them.** `src/` went from thirteen to eleven, and both losses are the ones `std` had taken away. What remains under `extern "c"` is CoreVideo, Core Graphics, Metal's device constructor, and libdispatch: platform API that `std` never offered and `translate-c` cannot read.

**Two local primitives are deliberately not covered, and saying so is half the point.** `Gate` in `src/clap/gui.zig` is a better structure than the mutex it replaced rather than a stand-in for one: a tick claims its place and learns whether the gate was open in a single atomic operation, which is the check-then-enter race a mutex would still have needed care around. `Io.Mutex` is now available and is still wrong, because its contended path calls `io.futexWait` and `Editor.tick` holds the gate across its whole body, so an unbounded wait there becomes one the host's main thread can enter in `Gate.close`. The libdispatch semaphore in `src/gpu/metal/renderer.zig` is a libc declaration too, but `std` did not hide it, and `Io.Semaphore` could not replace it regardless: the wait there is deliberately bounded and a blocking-only semaphore is the one shape that call site cannot use. Both sites say this at the source, so the convention is reachable from either direction and cannot be over-applied by someone who found only the ADR.

**One shared instance is safe across three threads, by construction rather than by luck.** `init_single_threaded` is a comptime value that uses no allocator, spawns no thread and installs no handler. The two functions reached through it do not touch it: `now` discards its userdata and calls `clock_gettime`, and `sleep` reaches `nanosleep` by way of a threadlocal only a runtime-spawned thread ever sets. That threadlocal is also why cancellation can never fire here, which is what lets the harness propagate `Cancelable` rather than justify swallowing it.

**Adopting the direction upstream is going costs less than tracking it later would.** [ADR 0002](./0002-zig-pinned-to-0-16-0.md) makes compiler upgrades deliberate scheduled work, and 0.16 was disruptive enough that this project already restates CLAP macros and Metal enums. Where `std` offers the primitive, taking it means the next release moves one file rather than three, and the surface taken is small on purpose: a clock and a sleep.

**`extern "c"` declarations still bypass the deployment-target check, and fewer of them does not fix that.** These are Zig's declarations, so no header availability attribute is ever read and the compiler will not report a problem. The two that were removed were both clear (`clock_gettime_nsec_np` is `__OSX_AVAILABLE(10.12)` against an 11.0 target, and `usleep` carries no annotation at all), so nothing was wrong; the hazard is that nothing would have said so. Read the SDK header's availability line before adding another. This is the same hazard already recorded for `CVDisplayLink`, and it now applies to a shorter list.
