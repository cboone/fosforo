# 0016. Verify the ring's memory ordering with Thread Sanitizer, off macOS

**Status:** Accepted

## Context

[ADR 0010](0010-lock-free-history-buffer.md) states the protocol between the audio thread and the render thread completely: the producer publishes an advanced cursor with release semantics and the consumer reads a trailing window relative to an acquire load of it. It says nothing about how that is checked, and nothing checked it.

Every test of `src/dsp/ring.zig` is single-threaded, so nothing ever ran `write` and `read` at once. Replacing the release store with a `.monotonic` one passed all 139 of them. The suite could not discriminate a correct ordering from an incorrect one, and a plain reading of the module was the only check that existed. That is a weaker guarantee than anything else in the file has.

The ordering is almost certainly correct. Release/acquire across a single-producer, single-consumer cursor is textbook, and it is what ADR 0010 specifies. What was missing is anything that would notice if it stopped being, and the realistic failure is not a wrong design but someone simplifying an atomic, watching the suite pass, and shipping it.

**This had been deferred three times** and needed a decision rather than a fourth. The premise carried along each hand-off was that a known signal drawn on screen during playback would be the first check able to tell the two apart. It is not. A weakened store's visibility window is nanoseconds against a trace that lags 20 ms and is redrawn sixty times a second, so a sine looks like a sine either way. Drawing a correct trace would have appeared to discharge the obligation without ever having tested it, which is worse than leaving it open.

Two routes were recorded as closed, and one of them was not.

**A threaded stress test is genuinely the wrong answer.** Racing two threads and checking for corruption measures how often this machine reorders, which is a property of the hardware and the day. A passing run says nothing and a failing run does not reproduce.

**Thread Sanitizer was recorded as unavailable, but the measurement behind that was target-specific.** Zig 0.16 links a `-fsanitize-thread` binary on `aarch64-macos` that segfaults before `main`, re-measured on 0.16.0 and Darwin 25.6.0 rather than inherited: it exits 139 without reaching its first `print`. Nothing had been tried off that target. `src/dsp/ring.zig` imports `std` and nothing else, with no Metal, no Objective-C, no CLAP and no `@embedFile`, which makes it the one part of the signal path with no reason to stay on macOS at all. The toolchain carries `tsan_platform_linux.cpp`, `tsan_rtl_amd64.S` and `tsan_interceptors_memintrinsics.cpp`, so a Linux x86-64 runtime is buildable and bulk `@memcpy` is instrumented rather than invisible.

**Thread Sanitizer is not a scheduler test**, which is the distinction the whole decision turns on. It does not look for corruption. It builds a happens-before graph from the atomic operations it observes and reports a data race when two threads reach the same address with no edge between them. A release store paired with an acquire load is that edge; a `.monotonic` store is not. The verdict is a property of the code, and it does not depend on the hardware reordering anything.

## Decision

Verify the release/acquire pairing by running `Ring.write` and `Ring.read` on two threads under Thread Sanitizer, on `x86_64-linux`, as a CI job. Guard against the weakening locally with a source canary in `zig build test`.

`src/ring_race.zig` is the harness, `zig build ring-race` the step, `scripts/ring-race-check` the judgement, and the `ring-race` job in `ci.yml` the thing that runs it.

## Consequences

**The harness has two arms, and one of them must fail.** Everything the real arm proves is an absence, and a search for absence succeeds for the wrong reason when the instrument was never running. The `weakened` arm is the same access pattern with the publishing store relaxed and must be flagged. An unlinked runtime, an uninstrumented `@memcpy`, a `pthread_create` the sanitizer never saw, or a job that built the wrong module all make both arms silent, and only the control tells that apart from a correct ring. `scripts/ring-race-check` therefore judges the control first and refuses to read anything into the ring's result until it has passed. That is the assertion order `scripts/smoke-leak-check` already uses, for the same reason.

**The writer cannot lap the reader, by construction rather than by margin, and that bound is load-bearing.** `Ring.read` deliberately tolerates a producer that laps it mid-copy and reports it through `coherent` instead of preventing it. On that path the reader genuinely reads slots the writer is concurrently writing with nothing ordering them, which is a data race in the model Thread Sanitizer implements, benign though it is here. This is the well-known seqlock limitation, and left unhandled it would make the job fail at random. So the harness emits at most `capacity - window_samples` samples over the whole run. A ratio would not do: a descheduled reader breaks any ratio, and the sanitizer slows everything down on a runner that is already noisy.

**What is verified, stated so it is not assumed to be more.** The release/acquire pair on the non-lapping path, which is the whole of what ADR 0010 specifies. Not the lapping path, which is outside the model by construction and which `coherent` covers exactly, single-threaded, because it is arithmetic. Not the ordering under a compiler other than the pinned one, and not on `aarch64-macos`, where the check cannot run.

**This is the first check here whose required machine capability is not being macOS,** and the first job in `ci.yml` that is not macOS-and-Zig. `zig build ring-race` refuses on a non-Linux host and names the job that does run it, rather than producing a binary that segfaults before it can say why. It still builds the harness there, so a type error fails on the development machine rather than in CI. That is the bargain `validate-shaders` and the smoke steps already make, a step allowed to require a capability the default build must not depend on, and it is why this is not wired into `zig build test` (ADR 0009, [ADR 0013](0013-gui-smoke-harness-as-a-build-step.md)).

**Being buildable off macOS turned out to be a property of `build.zig`, not only of the module.** The harness's module reaches `std` and `src/dsp/ring.zig` and nothing else, which is what made this possible at all, and that was still not sufficient. `b.dependency` runs a dependency's `build` function at configure time, and zig-objc's calls `appleSDKPath`, which panics on any OS that is not Darwin. The first CI run of this job therefore died inside a dependency's build script before a single step ran. `build()` now registers the race step and returns before constructing `Core` whenever the target is not macOS. Anything else that ever needs to build off this platform goes above that return.

**The canary is a text assertion and says so in its own name.** `zig build ring-race` needs a Linux host, so the machine this project is developed on is the one machine that cannot run it, and someone weakening an atomic here would see the suite pass and learn nothing until they pushed. The canary embeds the module's own source at comptime and asserts the five atomic operations are stated exactly as written, so the edit fails in `zig build test` on any machine. It proves nothing about behaviour. A passing canary means the lines are unchanged, not that they are correct, and this ADR is what "correct" rests on. It costs the shipped binary nothing, because Zig analyses `test` declarations only in a test build. A global find-and-replace across the file defeats it by rewriting its own string literals, which is accepted: the sanitizer job still catches that, and the canary's job is to be the faster of the two rather than the harder to fool.

**Measured rather than reasoned about, both directions.** Weakening `write`'s release store to `.monotonic` fails the canary and names the line; weakening `read`'s snapshot load does the same; both were reverted. The suite went from 139 tests to 144.

**The negative control is a replica, so the real `Ring` must be measured with a planted defect too**, once, and the result recorded here. A control that models the defect is not the same as the subject exhibiting it, and this project's own history with `leaks` is the reason that distinction gets written down: a grep for the public class name reported a planted leak as clean, and `leaks` cannot see a leaked `MTLBuffer` at all. Anyone adding a further atomic operation to `src/dsp/ring.zig` should plant a defect in it and confirm the job goes red before assuming this covers it.

**The deferral chain in `docs/plans/done/` is left as it stands.** Three completed plans point forward to each other, which is how this survived three hand-offs, and that is the useful part of the record. `docs/adr/README.md` already says to supersede rather than edit history. This ADR is the single live statement, and the historical documents keep their forward pointers to the issue that ended the chain.

## Amends ADR 0010

ADR 0010 stays Accepted. This adds the verification clause it never carried; it does not contradict anything in it.
