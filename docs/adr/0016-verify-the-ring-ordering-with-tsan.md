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

**The control arm has already paid for itself, on the first run.** Asking for `sanitize_thread` produced a binary that links the Thread Sanitizer runtime and emits none of its instrumentation, because Zig 0.16 defaults to its self-hosted x86_64 backend for a Debug build on Linux and that backend silently omits the pass. Nothing warns. The binary builds, links, runs, exits zero and reports no races whatever runs inside it, so the `ring` arm would have come back clean and the job would have gone green while measuring nothing at all. The deliberately racing arm reported nothing, `scripts/ring-race-check` stopped there, and `use_llvm = true` is the fix. This is the single strongest argument for the two-arm structure, and it arrived before the check had ever passed once.

**Being buildable off macOS turned out to be a property of `build.zig`, not only of the module.** The harness's module reaches `std` and `src/dsp/ring.zig` and nothing else, which is what made this possible at all, and that was still not sufficient. `b.dependency` runs a dependency's `build` function at configure time, and zig-objc's calls `appleSDKPath`, which panics on any OS that is not Darwin. The first CI run of this job therefore died inside a dependency's build script before a single step ran. `build()` now registers the race step and returns before constructing `Core` whenever the target is not macOS. Anything else that ever needs to build off this platform goes above that return.

**The canary is a text assertion and says so in its own name.** `zig build ring-race` needs a Linux host, so the machine this project is developed on is the one machine that cannot run it, and someone weakening an atomic here would see the suite pass and learn nothing until they pushed. The canary embeds the module's own source at comptime and asserts the five atomic operations are stated exactly as written, so the edit fails in `zig build test` on any machine. It proves nothing about behaviour. A passing canary means the lines are unchanged, not that they are correct, and this ADR is what "correct" rests on. It costs the shipped binary nothing, because Zig analyses `test` declarations only in a test build. A global find-and-replace across the file defeats it by rewriting its own string literals, which is accepted: the sanitizer job still catches that, and the canary's job is to be the faster of the two rather than the harder to fool.

**Measured rather than reasoned about, both directions.** Weakening `write`'s release store to `.monotonic` fails the canary and names the line; weakening `read`'s snapshot load does the same; both were reverted. The suite went from 139 tests to 144.

**The negative control is a replica, so the real `Ring` was measured with a planted defect as well.** A control that models the defect is not the subject exhibiting it, and this project's history with `leaks` is why that distinction gets written down: a grep for the public class name reported a planted leak as clean, and `leaks` cannot see a leaked `MTLBuffer` at all. Both halves of the pairing were planted in `src/dsp/ring.zig`, on a throwaway branch, and both were caught:

| Planted defect                                 | `ring` arm | Harness's own validation        |
| ---------------------------------------------- | ---------- | ------------------------------- |
| `write`'s release store to `.monotonic`        | data race  | `ring ok`, 4096 windows, 0 torn |
| `read`'s acquire snapshot load to `.monotonic` | data race  | `ring ok`, 4096 windows, 0 torn |

The second column is the finding and the third is why it was needed. In both cases the harness's own data validation passed completely: 4096 consecutive windows, every one of them a correct run of the writer's sequence, nothing torn. **The weakening does not show up as corruption**, which is exactly what the deferral chain assumed it eventually would and is why drawing a trace could never have closed this. The sanitizer is the only thing in either run that noticed.

**The first of those measurements found a real gap in the harness**, which is the argument for making it an acceptance criterion rather than a formality. The reader consulted `Ring.written()` before every read, to avoid spending an instrumented copy discovering the ring was still empty. `written()` is itself an acquire load, so per-iteration it ordered the writer's stores against the copies that followed: it detected a weakened publishing store and would have reported a weakened acquire load inside `read` as clean. Half the protocol was uncovered by a line that read as an optimization. The wait now happens once, before the loop, which also matches the plugin, whose consumer never consults the cursor separately.

Anyone adding a further atomic operation to `src/dsp/ring.zig` should plant a defect in it and confirm the job goes red before assuming this covers it.

## Amendment: what this covers beyond the ring (#91)

The obligation above was scoped to one file, and four more cross-thread mechanisms had arrived since. [#91](https://github.com/cboone/fosforo/issues/91) extends the structure to the one of them that both matters most and can be reached at all, and establishes the rule that decides the rest.

**A Thread Sanitizer arm can discriminate an ordering only where that ordering guards non-atomic memory.** TSan reports two threads reaching one address with no edge between them; two relaxed atomic accesses to the same word are not a race in that model whatever their ordering. So the question to ask of any candidate is not "does it cross threads" but "what plain memory does its release make safe to touch". That sorts the four:

| Mechanism          | The non-atomic memory it guards                                                       | Arm         |
| ------------------ | ------------------------------------------------------------------------------------- | ----------- |
| `Ring`             | `samples: []f32`                                                                      | Has one     |
| `Gate`             | The editor's own fields, written by `destroy` after `close` and read by `tick` inside | Now has one |
| `Pending`          | **None.** The whole message is inside the `u64`                                       | Cannot      |
| `renderer.Mailbox` | `Pipelines`, which are Objective-C objects                                            | Cannot      |

**`Gate` moved to `src/clap/gate.zig` to get one.** `src/clap/gui.zig` reaches CLAP's translated headers, `objc` and CoreVideo, so it cannot be built for `x86_64-linux` at all; `Gate` reaches nothing but `std`. `src/gate_race.zig` is the harness and `zig build gate-race` the step.

**Three of the four names the Decision above gives have moved**, and the sentences there are left standing on this ADR's own rule rather than edited. `scripts/ring-race-check` is now **`scripts/race-check`**, parameterized with a harness path, a clean arm, a weakened arm and the field whose value proves the two threads met, so the assertion order that makes a control-first judgement work is written once for both harnesses rather than copied. The `ring-race` **job** is now **`race`** and runs both steps, because the sanitizer runtime is built from compiler-rt once per job and the second binary reuses it; re-measured at 84s max over 12 runs against the ring's 88s over 8, so the second harness did not move the ceiling and a second job would only have paid that build again. `src/ring_race.zig` and `zig build ring-race` keep their names. Both harnesses print under a `race:` prefix so the script's greps take one shape.

**The harness stands a plain `[]u64` in for the editor's fields**, read by a holder inside the gate and written by the closer after `close` returns, which is `Editor.destroy`'s shape with everything Apple owns removed. Without that payload both arms come back clean and the harness measures nothing. Three details are load-bearing and each looks incidental, so each has a canary in `zig build test` rather than a comment alone: the rendezvous flag is relaxed on both sides, because release-acquire there supplies the very edge under test; the closer writes the payload before `join`, because `join` is itself an edge; and the replica differs from the real `Gate` in exactly one ordering. All three were confirmed by planting them and watching the named test fail.

**A fourth detail was found by the check going red, and it is the one nobody would have predicted: how long a thread takes to leave the gate is itself a function of the ordering under test.** The first complete run failed on the control, which Thread Sanitizer had flagged exactly as intended, because the harness's own `contended` counter was zero: `close` had not spun in a single one of its 256 rounds, against 195 for the clean arm on the same commit. That asymmetry is systematic. TSan instruments a release store as a full publish of the accessing thread's vector clock and a relaxed store as very much less, so the weakened arm's holder reached `leave` and was gone before the closer arrived, and the control had quietly stopped closing a gate with a tick inside it — which is the only situation either arm exists to model. **The repair is to hold rather than to relax the assertion**, because the assertion was right: the holder now spins a fixed count before leaving, which costs the same in both arms because it touches nothing being varied. Both arms then contend in 256 rounds of 256, with total spins of 251,607 and 252,026, 0.17% apart. **The general form is worth carrying to any future arm:** a control that models a defect can be made unfaithful by the instrument's own cost, and the counter that proves the two threads met is the only thing that would say so.

**All five of `Gate`'s orderings were planted in the real type, one at a time, on a throwaway branch.** The predictions were written down first and the table is what came back:

| Planted defect                                           | `gate` arm | Run                                                                       |
| -------------------------------------------------------- | ---------- | ------------------------------------------------------------------------- |
| `enter`'s `fetchAdd(one_tick, .acquire)` to `.monotonic` | clean      | [34274029084](https://github.com/cboone/fosforo/actions/runs/34274029084) |
| `enter`'s refusal `fetchSub(one_tick, .release)`         | clean      | [34274560328](https://github.com/cboone/fosforo/actions/runs/34274560328) |
| `leave`'s `fetchSub(one_tick, .release)` to `.monotonic` | data race  | [34273862796](https://github.com/cboone/fosforo/actions/runs/34273862796) |
| `close`'s `fetchOr(closed, .acquire)` to `.monotonic`    | clean      | [34274400169](https://github.com/cboone/fosforo/actions/runs/34274400169) |
| `close`'s spin `load(.acquire)` to `.monotonic`          | data race  | [34274161852](https://github.com/cboone/fosforo/actions/runs/34274161852) |

Both races were reported against the payload write. The two that flag are the two halves of one edge, `leave`'s release paired with the acquire load in `close`'s spin, and that edge is the whole of what makes teardown safe. The three that come back clean are not thereby shown to be unnecessary; they are shown to be outside what any sanitizer can see, which is a different statement and the reason the canary still pins all five.

**The issue as filed specified the wrong defect for the control arm**, and this is why the plants were run rather than assumed. Its acceptance table named `enter`'s acquire relaxed, which is row one: clean. Had the control been built that way it would have reported nothing, `scripts/race-check` would have refused the run, and the failure would have read as a broken sanitizer rather than as the wrong defect to plant. The weakened replica relaxes `leave`'s release instead.

**`Pending` gets no arm, and that is a measurement rather than a concession.** Its whole message is packed into one `u64`, so a weakened `post` leaves two relaxed atomic accesses and nothing to report. Rather than assert that, a 2x2 was run over its shape: with and without one thing riding alongside the word, and with `post` releasing and relaxed. Written once after the taker is spawned, so that thread creation is not itself the edge, which the first attempt got wrong and which is why the correct-ordering payload arm is in the table:

| Arm                        | Rides alongside | `post`       | Races | Took |
| -------------------------- | --------------- | ------------ | ----- | ---- |
| `pending`                  | no              | `.release`   | 0     | 2268 |
| `pending-weakened`         | no              | `.monotonic` | **0** | 548  |
| `pending-payload`          | yes             | `.release`   | 0     | 55   |
| `pending-payload-weakened` | yes             | `.monotonic` | **2** | 2    |

Row four is what makes row two mean something: the weakening _is_ detectable when anything rides along, so row two is a fact about `Pending`'s shape and not about the instrument. Measured in [34275109417](https://github.com/cboone/fosforo/actions/runs/34275109417); the arms were temporary and are not in the tree. Two consequences. `Pending` stays in `src/clap/gui.zig` with its canary and its unit tests, and the `gpu.Size` extraction the issue proposed to enable a `Pending` arm was not needed and was not done. And **if a field is ever added that the `u64` does not carry**, a pointer to a heap-allocated update most obviously, the release becomes load-bearing in a way a sanitizer could see, and this decision should be revisited rather than cited.

**Two things stay outside any sanitizer, stated here so they are not rediscovered.** `renderer.Mailbox` publishes `Pipelines`, which are Objective-C objects, so its module cannot be built for Linux at all; it has unit tests and a `canary.statedBefore` check, which is the one thing counting cannot do, because its two statements are individually correct in either order. And the watcher thread in `src/gpu/metal/renderer.zig` is never run under Thread Sanitizer anywhere.

**One limitation of the canary got sharper here, and it has a second guard.** ADR 0016 accepts that a global find-and-replace defeats a text canary by rewriting its own string literals, on the grounds that the sanitizer job still catches it. Planting the harness's own rendezvous flag showed the first half of that concretely: a careless `perl -pi -e` rewrote the assertion along with the code and the suite stayed green. The second half holds too, and by a different route than for the ring. If the rendezvous became a genuine release-acquire pair, both arms would come back clean, and `scripts/race-check` refuses on the control before it reads the subject at all. The two checks are complementary rather than redundant, and neither alone is enough.

**The deferral chain in `docs/plans/done/` is left as it stands.** Three completed plans point forward to each other, which is how this survived three hand-offs, and that is the useful part of the record. `docs/adr/README.md` already says to supersede rather than edit history. This ADR is the single live statement, and the historical documents keep their forward pointers to the issue that ended the chain.

## Amends ADR 0010

ADR 0010 stays Accepted. This adds the verification clause it never carried; it does not contradict anything in it.
