# Verify the history buffer's memory ordering

Issue [#44](https://github.com/cboone/fosforo/issues/44). Follows [#35](https://github.com/cboone/fosforo/issues/35), which landed the container, and [#37](https://github.com/cboone/fosforo/issues/37), which ended the deferral chain and routed the decision here.

## Context

`src/dsp/ring.zig` publishes its cursor with a release store (`write`, line 183) and reads it with an acquire load (`read`, line 273). That pairing is the whole of ADR 0010's protocol between the audio thread and the render thread. Every test of the module is single-threaded, so replacing the release with a `.monotonic` store passes all 139 of them. Nothing in the repository would notice.

The ordering is almost certainly correct. This is about verification and regression. The realistic failure is someone simplifying an atomic, watching the suite pass, and shipping it, and the obligation has already survived three hand-offs between plans in `docs/plans/done/` without being closed.

The premise those hand-offs carried, that drawing a known signal on screen would discriminate a correct ordering from a weakened one, does not hold: a weakened store's visibility window is nanoseconds against a trace that lags 20 ms and redraws sixty times a second. Closing this by drawing a trace would discharge the obligation with a check that never tested it.

**The decision, recorded here and then durably in ADR 0016: verify it with Thread Sanitizer on `x86_64-linux`, in CI, and guard it locally with a source canary.**

### Why TSan is available after all

`AGENTS.md:155` closes this route, but the closure is target-specific: "Zig 0.16 accepts `-fsanitize-thread` and links a binary on **`aarch64-macos`** that segfaults on startup". Nothing was ever tried off that target, and `src/dsp/ring.zig` is the one part of the signal path with no reason to stay on it. Its only imports are `std` and `std.testing`. No `objc`, no `clap_c`, no `@embedFile`, no framework, no `extern "c"`, no `builtin.target` branch.

The pinned toolchain ships what is needed. `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/libtsan/` carries `tsan_platform_linux.cpp`, `tsan_rtl_amd64.S` and `tsan_interceptors_memintrinsics.cpp`, so a Linux x86-64 runtime is buildable and bulk `@memcpy` is instrumented rather than invisible. `std.Build.Module` exposes `sanitize_thread: ?bool` as a per-module option, so one module can carry it without the plugin's modules acquiring it.

### Why this is not the scheduler test the issue rules out

The issue rules out a threaded stress harness because "how often this machine reorders is a property of the hardware and the day". That objection is about **detecting corruption**, and it is correct: a stress test passes or fails by luck.

TSan does not detect corruption. It builds a happens-before graph from the atomic operations it observes and reports a data race when two threads touch the same address with no edge between them. A release store paired with an acquire load creates that edge, so the correct ring is clean. A `.monotonic` store creates no edge, so the same access pattern is reported, **whether or not the hardware ever reorders anything**. The verdict is a property of the code, which is exactly what the issue asked for and what a stress harness could not give.

### The hazard that shapes the harness

`Ring.read` deliberately tolerates a producer that laps the reader mid-copy and reports it through `coherent` rather than preventing it. On that path the reader genuinely reads slots the writer is concurrently writing, with no happens-before edge, which is a data race in the model TSan implements. **TSan will flag the correct ring whenever tearing occurs.** This is the well-known seqlock limitation, and left unhandled it would produce a job that fails at random.

So the harness must make lapping **impossible by construction, not improbable**: the writer emits at most `capacity - window` samples over the whole run, so it can never reach the reader's slots however badly either thread is scheduled. A ratio argument is not enough, because a descheduled reader breaks any ratio, and TSan slows everything by a large factor on a noisy runner.

That bound costs no coverage of the thing under test. The edge being verified is cursor-store to cursor-load, and it is exercised on every read: the reader acquires a cursor the writer released and copies the slots that store published. Wraparound is index arithmetic and is already tested exactly, single-threaded.

## What lands

| File                                                  | Change                                                                      |
| ----------------------------------------------------- | --------------------------------------------------------------------------- |
| `src/ring_race.zig`                                   | New. The two-thread harness, two arms, on `src/smoke.zig`'s precedent.      |
| `src/dsp/ring.zig`                                    | Docstring and the comment at the store rewritten. Source canary test added. |
| `build.zig`                                           | New `ring-race` step and its own module.                                    |
| `scripts/ring-race-check`                             | New. Judges both arms, on `scripts/smoke-leak-check`'s precedent.           |
| `.github/workflows/ci.yml`                            | New `ring-race` job on `ubuntu-latest`.                                     |
| `.editorconfig`                                       | Add `scripts/ring-race-check` to the shell section.                         |
| `docs/adr/0016-verify-the-ring-ordering-with-tsan.md` | New. The durable record.                                                    |
| `docs/adr/0010-lock-free-history-buffer.md`           | Amended in place, pointing at 0016.                                         |
| `docs/adr/README.md`                                  | New row in the table.                                                       |
| `AGENTS.md`                                           | Line 155 rewritten.                                                         |
| `CHANGELOG.md`                                        | Entry under `### Added`.                                                    |

`docs/plans/done/` is left untouched. It is the historical record, `docs/adr/README.md` already says to supersede rather than edit history, and how this survived three hand-offs is itself the useful lesson.

## Work

### 1. Re-measure TSan on `aarch64-macos` first

Cheap, and if it passes the whole design collapses into something better: no new runner, and the check runs on the machine the project is developed on. Build a throwaway two-thread program with `.sanitize_thread = true` for the host and run it.

Expect it to fail, since three documents record that it does. Record the result either way, with the Zig version, because that claim is about to be quoted in an ADR.

### 2. `src/ring_race.zig`, the harness

Takes a `std.process.Init.Minimal` and dispatches on `argv[1]`, exactly as `src/smoke.zig` does. Two arms, each its own process run:

- **`ring`** drives the real `Ring`. Must be clean.
- **`weakened`** drives a harness-local replica of the same shape whose publish is `.monotonic`. Must be flagged. It is the negative control and its only job is to be wrong, so it carries a comment saying so and saying it must never be copied.

The two arms differ in exactly one thing, the ordering of the publishing store. Everything else, the loop bounds, the block size, the window size and the validation, is shared.

Shape of an arm:

- Allocate a ring of `1 << 20` samples. Window `960`, matching what `gui.windowSamples` yields at 48 kHz.
- Spawn a reader thread. It loops `Ring.read` into a stack window, and on `true` validates the window against the writer's known sequence, counting successful reads. Validation is what makes a passing arm mean the reader consumed the writer's samples through the cursor rather than merely surviving.
- The writer, on the main thread, writes blocks of 256 samples of a known ramp, **stopping at `capacity - window` samples total**, per the hazard above.
- Join, then assert three things and print one line per arm, all of which the script reads:
  - the reader completed at least N successful reads, so the arms did overlap and a clean result is not vacuous,
  - `torn == 0`, which the writer bound guarantees; a non-zero count means the bound broke and the run is void rather than passing,
  - every validated window was correct.

The writer's ramp doubles as a data check, so an arm that somehow corrupts the buffer fails on its own terms without waiting for TSan.

Both threads must be created through `std.Thread.spawn` with libc linked, because TSan learns about threads by intercepting `pthread_create`. Without libc, Zig issues a raw `clone`, TSan never sees the thread, and both arms come back clean, which is the exact false pass the control arm exists to catch.

### 3. `build.zig`: the `ring-race` step

A fresh module, not `Core.module`. That constructor unconditionally adds `objc`, `clap_c`, the anonymous `scope.metal` import and five Apple frameworks, none of which can link on Linux.

```zig
const mod = b.createModule(.{
    .root_source_file = b.path("src/ring_race.zig"),
    .target = b.resolveTargetQuery(.{}),
    .optimize = .Debug,
    .link_libc = true,
    .sanitize_thread = true,
});
```

Three details are load-bearing:

- **`b.resolveTargetQuery(.{})` rather than the shared `target`.** `build()`'s target carries `os_version_min = 11.0.0` as a deployment floor for macOS. Resolved on Linux that becomes a nonsensical minimum kernel version. The ring has no deployment target, so it takes a bare host query.
- **`link_libc = true`**, for the `pthread_create` interception above.
- **`.Debug`**, matching `zig build test`. Atomic orderings survive every optimization level, so this is not a coverage gap.

The step runs `scripts/ring-race-check` with the harness binary, mirroring `smoke-leaks` (`addFileArg`, `stdio = .inherit`, `has_side_effects = true`). On a non-Linux host it resolves to `b.addFail(...)` naming the CI job instead, on `validate-shaders`' precedent: a step is allowed to require a machine capability, and this is the first one whose required capability is not being macOS.

Never wired into `zig build test`, for the reason `build.zig:266-272` already gives about the smoke harness and ADR 0009 gives about hermeticity.

### 4. `scripts/ring-race-check`

Bash, `set -euo pipefail`, the header-comment style and exit codes of `scripts/smoke-leak-check` (64 usage, 65 data, 66 missing binary). Runs with `TSAN_OPTIONS="halt_on_error=0 exitcode=66"`.

The order of the assertions is the point, as it is in the leak script:

1. **The weakened arm ran and TSan reported a data race in it.** If it did not, the instrument is not detecting anything and every check below would be vacuous. This is the same reasoning that makes the leak script assert a parseable report exists before searching it for absence, and it independently catches an unlinked runtime, an uninstrumented `memcpy`, a `pthread_create` TSan never saw, and a misconfigured job.
2. **The `ring` arm ran to completion and printed its overlap statistic**, so a clean result describes two threads that actually contended.
3. **The `ring` arm reported no data race**, judged on both the exit code and `WARNING: ThreadSanitizer` in the output.

Add the script to `.editorconfig`'s shell section in the same commit. The `shell` job selects files by shebang so it lints a new script immediately, while `.editorconfig` styles it only once listed, and that asymmetry reports tabs against a file matching its siblings exactly.

### 5. The source canary in `src/dsp/ring.zig`

A test that `@embedFile`s the module's own source and asserts the atomics are still literally there, so the weakening fails in `zig build test` on any machine rather than only on push. It costs the shipped binary nothing: Zig analyzes `test` declarations only in a test build, so the embed is never referenced by `zig build`.

It asserts the four exact call sites and that `.monotonic` appears exactly once, which is the producer's own unsynchronized self-read:

```zig
"self.cursor.store(at + input.len, .release);"
"return self.cursor.load(.acquire);"
"const at = self.cursor.load(.acquire);"
"return coherent(at, self.cursor.load(.acquire), cap, copied);"
```

Counted with `std.mem.count` rather than merely found, so an added atomic is noticed too. Its name says out loud what it is, so it cannot be misread as behavioural proof, in the style the rest of the file already uses:

> `test "the release store is still a release store, checked as text because no test here can check it as behaviour"`

Its doc comment carries the explanation and points at ADR 0016 and `zig build ring-race`.

### 6. Rewrite what is now false

Three passages assert that nothing verifies the ordering. Once the job lands they are wrong, and leaving them is worse than the original gap.

- `src/dsp/ring.zig:21-30`, the docstring paragraph beginning "**Those two orderings are unverified by anything here**". Replace with what now checks them, how to run it, and the seqlock boundary: TSan covers the release/acquire pair on the non-lapping path, and the lapping path is outside its model by construction, which is what `coherent` covers exactly and single-threaded.
- `src/dsp/ring.zig:176-182`, at the store: "**No test in this project can catch you weakening this**". Now two things can. Name both.
- `AGENTS.md:155`. Rewrite wholesale. Note it also contains a plain error to fix: it says "three plans in `docs/plans/done/` say it will" close by drawing the trace, but `2026-08-19-read-a-trailing-window-and-upload-it-across-the-seam.md:202-206` says the opposite at length. Only #35's and #36's plans carry that premise.

### 7. The CI job

In `ci.yml` rather than its own workflow. That file's `paths-ignore` covers `*.md`, `docs/**`, `LICENSE` and the agent config files, none of which can hide a change to `src/dsp/ring.zig` or `build.zig`, so the check cannot skip the change that governs it. This is the opposite of `typos`, which needed its own workflow for exactly that reason.

```yaml
  ring-race:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1
        with:
          version-file: build.zig.zon
      - name: Race-check the history buffer
        run: zig build ring-race
```

The header comment states why it is Ubuntu (the check cannot run on the development machine, which is the point of ADR 0016, and Ubuntu bills at a tenth of macOS), and that the ceiling is **borrowed rather than measured**, per `AGENTS.md:162`. Ten rather than the eight the other borrowed ceilings use, because Zig builds the TSan runtime from C++ sources on a cold cache and nothing here has measured that. Replace it with a real figure and sample size once this pull request's runs supply one, the way every other ceiling was set (#17).

### 8. ADR 0016, and the amendment to 0010

`docs/adr/0016-verify-the-ring-ordering-with-tsan.md`, in the project's exact ADR shape: `# 0016. Title`, `**Status:** Accepted`, then `## Context`, `## Decision`, `## Consequences`. Add its row to `docs/adr/README.md`.

ADR 0010 specifies the protocol and imposes no verification obligation, which is the hole this sat in. Amend it in place with a dated, issue-attributed section pointing at 0016, on the precedent `0013-gui-smoke-harness-as-a-build-step.md:55` set with `## Amended by issue #5`. It is not superseded: 0016 adds a clause rather than contradicting one, so 0010 stays Accepted.

The ADR must state the boundary honestly, since that is what stops this being closed by something that never tested it:

- What is verified: the release/acquire pair on the non-lapping path, which is the whole of what 0010 specifies.
- What is not: the lapping path, which is a benign-by-design race the model calls undefined and TSan cannot validate. `coherent` covers it, exactly and single-threaded.
- That the check does not run on `aarch64-macos`, with the re-measurement from step 1 as evidence rather than as inheritance.
- That the negative control is a replica, and that the real `Ring` was measured with a planted defect once, with the result.

Then a `CHANGELOG.md` entry under `### Added`, citing [#44] and [ADR 0016] in the file's existing link style.

## Verification

Everything below runs on Linux, since that is where the check lives. Locally on this Mac only steps 4 and 5 are available.

1. `zig build ring-race` passes: the weakened arm is flagged, the ring arm is clean, both report overlap.
2. **Planted defects on the real `Ring`, which is the acceptance criterion and not optional.** A clean result means nothing until the instrument has been shown to catch the thing it exists to catch, and the negative control is a replica rather than the subject. Three edits, each reverted after measuring, each result recorded in ADR 0016:
   - `write`'s store to `.monotonic`. The `ring` arm must be flagged.
   - `read`'s snapshot load to `.monotonic`. The `ring` arm must be flagged.
   - Delete the `weakened` arm's race. The script must fail at assertion 1 rather than pass.
3. Source canary: with `write`'s store weakened, `zig build test` fails on this Mac. Reverted, 139 tests pass and the count is unchanged.
4. `zig build`, `zig build test`, `zig fmt --check build.zig src/` all clean.
5. `git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d` and the same piped to `shellcheck`, both clean, with `scripts/ring-race-check` in the set. `typos` clean.
6. `zig build smoke-gpu` and the CLAP still build and load, confirming the new module changed nothing about the plugin's own.
7. On the pull request: the `ring-race` job is green, and its duration is recorded so the borrowed ceiling can be replaced with a measured one.

The planted-defect measurements need a Linux host. If none is at hand, run them on a throwaway commit and read the CI result, which is slower but is the same evidence.

## If TSan on `x86_64-linux` does not work

It has not been tried in this repository, and Zig's sanitizer support is not uniformly solid. If the runtime fails to build, fails to link, or reports nothing in the weakened arm:

1. Try `aarch64-linux` on an `ubuntu-24.04-arm` runner. `tsan_rtl_aarch64.S` ships too.
2. Try `x86_64-linux-musl` if glibc interception is the problem, accepting that TSan's interceptors target glibc and this may be the wrong direction.

If none works, fall back to the issue's other lane: correct by construction, guarded by the source canary alone. **Write ADR 0016 either way**, recording the measurements and the choice. The one outcome this plan must not produce is a fourth deferral.

## Out of scope

- **Changing the ordering.** Nothing here suggests the current pairing is wrong, and the harness exists to keep it that way.
- **A threaded stress harness that judges by corruption**, for the reason the issue gives. The harness here judges by TSan's verdict and by data validation, never by whether corruption happened to appear.
- **The rest of ADR 0010's protocol.** `coherent` is pure arithmetic and is already tested exactly.
- **`docs/plans/done/`.** Left as history, by decision.

## Commits

1. `test: run the history buffer's protocol under Thread Sanitizer (#44)` (harness, build step, script, `.editorconfig`)
2. `test: catch the ring's atomics being weakened locally (#44)` (source canary)
3. `ci: race-check the history buffer on Linux (#44)`
4. `docs: record how the ring's memory ordering is verified (#44)` (ADR 0016, 0010's amendment, README row, `AGENTS.md`, the two `ring.zig` passages, CHANGELOG)
