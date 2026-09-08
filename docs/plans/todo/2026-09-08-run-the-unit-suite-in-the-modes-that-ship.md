# Run the unit suite in the modes that ship

Issue: [#94](https://github.com/cboone/fosforo/issues/94), item 6 of
[the verification-gaps program](2026-09-04-close-the-verification-gaps-in-the-test-suite.md).
Type: `ci:`. Lane: free — needs no host, no GPU, no window server.

## Context

`addTestStep` (`build.zig:489-502`) builds one test artifact from the shared `optimize`
value. `standardOptimizeOption` (`build.zig:28`) declares no default and the reusable CI
workflow passes no `-Doptimize`, so **every test this project has ever run has been a
Debug build**, while the shipped CLAP is `--release=fast`. The convention that "every
trust boundary refuses rather than asserts" — stated at `ring.zig:83-91`,
`plugin.zig:504-514`, `gui.zig:63-67` and `state.zig:155-164` — has therefore only ever
been checked in the build where the asserts are still there to catch a lapse.

This closes that by adding two pinned test steps beside the existing one, and a CI job
that runs both.

### What the exploration measured, before any change

All three modes already pass, 285/285. Cold build-and-run on this machine, each in its
own cache directory:

| Mode          | Cold build + run | Test binary | `reached unreachable code` | `std.debug.assert` | Safety checks |
| ------------- | ---------------- | ----------- | -------------------------- | ------------------ | ------------- |
| `Debug`       | 5.49 s           | 4,630,248 B | present                    | live               | on            |
| `ReleaseSafe` | 9.65 s           | 1,912,376 B | present                    | live               | on            |
| `ReleaseFast` | 10.68 s          | 1,928,504 B | **absent**                 | **stripped**       | **off**       |

The `reached unreachable code` column is a free positive control that the modes really
differ: it is the panic string a failing `std.debug.assert` reaches, and `strings -a` finds
it in the Debug and ReleaseSafe binaries and not in the ReleaseFast one.

Both of the issue's "measure rather than assume" items came back clean, and each for a
reason worth keeping:

- **No test depends on Debug-only trapping.** Every narrowing that would have wrapped has
  already been converted to a total form, and two of them name this issue as the reason:
  `measure.Image.complete` (`measure.zig:76-83`, comment at `:65-75`) and its `verdict.Picture`
  twin (`verdict.zig:142-143`). `state.zig:155-166` reaches for `@panic` over
  `std.debug.assert` on the same grounds.
- **`palette.zig`'s float tolerances survive**, down to the 1e-7 at `palette.zig:751-753`.
  There is no `@setFloatMode` anywhere in `src/`, Zig does not enable fast-math in
  ReleaseFast, the transcendentals are libm calls rather than codegen, and
  `decay_tau_nanos` is comptime-folded (`palette.zig:330-332`).

### Three findings that change what this issue should say

1. **The `ci` job cannot host the step.** It is `uses: cboone/gh-actions/.github/workflows/run-zig-ci.yml@91f9abd`
   (`ci.yml:65-71`), a reusable workflow with no hook for an extra step. The issue's shape
   ("a step in the `ci` job beside the existing one") is not available. A new repo-local job
   is what replaces it.
2. **`assert(fba.end_index == 0)` (`plugin.zig:524`) is vacuous today**, in every mode.
   `scratchBytes` returns `0` unconditionally (`plugin.zig:376-379`), and `passThrough`
   (`plugin.zig:549-550`) and `tap` (`plugin.zig:617-618`) both take the allocator and
   discard it deliberately, so `end_index` is structurally always zero. It is a tripwire for
   a future step that wants scratch, not a live check, so it is the wrong example for the
   issue to lead with. The convention it stands for is real; that one line is not evidence of it.
3. **One test goes vacuous under ReleaseFast**, which is why the Debug step stays.
   `shader.zig:278-285` asserts `!live`, and `live` is `builtin.mode == .Debug and !builtin.is_test`
   (`shader.zig:45`). In ReleaseFast the first clause already fails, so the `!builtin.is_test`
   plant the test exists for stops being covered; `iface.zig:642-646` confirms nothing else
   covers it. The new steps are strictly additive and must never replace `zig build test`.

## Decisions

| Question               | Decision                                                                                       |
| ---------------------- | ---------------------------------------------------------------------------------------------- |
| Where the CI check goes | A new `test-modes` job in this repo's `ci.yml`                                                 |
| `zig build test`       | Stays mode-following, so `-Doptimize=ReleaseSmall` and friends remain available ad hoc         |
| `ReleaseSafe`          | **Added** as `test-safe`, not refused: it is the only mode that optimizes *and* keeps the checks |
| Instrument check       | A comptime pin, so a dropped optimize mode is a compile error rather than a silently green job |

## Changes

### 1. `build.zig` — three test steps from one function

**Extract the `Core` literal.** `build.zig:44-57` becomes a call to a new
`coreAt(b, target, provenance, optimize) Core`, so a second and third graph can be built at
a pinned mode with `clap_c`, `objc` and `shader_path` all re-derived rather than inherited.
`shader_path` in particular must be re-derived: `debugShaderPath` returns `""` for any
non-Debug mode (`build.zig:190-191`), and copying the Debug value into a pinned Core would
bake an absolute worktree path into a release-mode binary, which is the exact negative
`debugShaderPath`'s docstring (`:173-178`) and `ci.yml:812-828` exist to hold.

`b.dependency` is the only eager cost, and it is small: `xcrun` measures ~10 ms warm against
a whole-graph configure of 118 ms. Zig caches a dependency instance by its argument hash, so
when `-Doptimize=ReleaseFast` is passed the release Core reuses the shared one rather than
adding a fourth. **Measure the configure delta after the change** (`time zig build --help`
before and after) and put the figure in the comment, on this file's practice.

**`Core.Options` gains `pinned_optimize: []const u8 = ""`**, published through the existing
`b.addOptions()` block in `Core.module` (`build.zig:303-325`) as
`build_options.addOption([]const u8, "pinned_optimize", options.pinned_optimize);`. A string
rather than an enum, because `addOption` handles `[]const u8` unambiguously and `@tagName`
makes the comparison trivial.

**`addTestStep` takes a name, a description and the pin.** Its body is otherwise unchanged,
including the two anonymous imports and the docstring at `:473-488` explaining why they are
on the test module alone. Three call sites replace `build.zig:98`:

```zig
addTestStep(core, "test", "Run unit tests", "");
addTestStep(coreAt(b, target, provenance, .ReleaseSafe), "test-safe",
    "Run unit tests at ReleaseSafe: optimized, with asserts and safety checks live", "ReleaseSafe");
addTestStep(coreAt(b, target, provenance, .ReleaseFast), "test-release",
    "Run unit tests in the optimize mode that ships (ReleaseFast)", "ReleaseFast");
```

The docstring on `addTestStep` gains the paragraph this issue is for: what each mode sees,
that the three are additive rather than alternatives, and the `shader.zig:278` vacuity that
is the concrete reason the Debug step cannot be dropped.

`ring-race`'s comment at `build.zig:617-618` ("Debug, matching `zig build test`") stays
correct and stays as it is, since `test` remains mode-following.

### 2. `src/main.zig` — the comptime pin

A file-scope `comptime` block, next to the module-sweep test, that fails the build if a
pinned artifact was compiled at the wrong mode:

```zig
comptime {
    if (build_options.pinned_optimize.len != 0 and
        !std.mem.eql(u8, build_options.pinned_optimize, @tagName(builtin.mode)))
    {
        @compileError("this test artifact is pinned to " ++ build_options.pinned_optimize ++
            " and was built at " ++ @tagName(builtin.mode) ++ "; see addTestStep in build.zig");
    }
}
```

Comptime rather than `std.debug.assert`, on the reason `src/platform/io.zig:59-62` already
states: a failing comptime assert is a compile error in every optimize mode, which is the
only kind of assertion that survives the build it is making a claim about.

**One thing to re-check while editing this file.** `src/main.zig:105-161` ties the module
list to the import list with `expectEqual(sources.len, listed + 4)`, where `listed` counts
occurrences of `_ = @imp` ++ `ort("`. A file-scope `const build_options = @import("build_options");`
does not match that pattern and `build_options` is not a `src/` file, so the arithmetic
should be unaffected — confirm it rather than assume it, since that test is what stops the
sweep convention lapsing.

### 3. `.github/workflows/ci.yml` — one new job

One job rather than two, on the `smoke` job's stated reasoning that the checkout and the Zig
install are paid once for all of its halves, and two named steps inside it so a failure is
attributable to a mode:

```yaml
  test-modes:
    runs-on: macos-latest
    timeout-minutes: 8
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1
        with:
          version-file: build.zig.zon
      - name: Run unit tests at ReleaseSafe
        run: zig build test-safe
      - name: Run unit tests in the mode that ships
        run: zig build test-release
```

Both pins copied verbatim from the `shaders` job (`ci.yml:83-116`), which is the nearest
neighbour: macOS, repo-local, one concern. `macos-latest` is not negotiable — the module
links five Apple frameworks and `b.dependency("objc", ...)` panics at configure time on any
other OS (`build.zig:30-42`).

**The `timeout-minutes` above is provisional and must not be merged unmeasured.** Every
ceiling in this workflow carries its figure and sample size in a comment beside it. Open the
PR with `8` (the value every other macOS job here uses), read the actual duration from the
first two or three runs through the Actions API, and set the final value at roughly 4x with
the measurement written into the comment. The local numbers bound the compile half at about
20 s for the two modes together; the rest is checkout and the Zig install.

**Branch protection is a manual follow-up.** `test-modes` is a new check name and will not
be required until it is added, the same way `smoke-appkit` needed a step outside the
repository when #72 promoted it.

### 4. Documentation, landing with the code

- **`AGENTS.md` Development block** (near line 113): add `zig build test-safe` and
  `zig build test-release` with one-line descriptions.
- **`AGENTS.md`'s "`zig build test` is a Debug build" gotcha** (line 359): this is the bullet
  the issue is named against. It keeps the lazy-analysis half intact and gains the three-step
  table, the vacuity finding at `shader.zig:278`, and the correction that
  `assert(fba.end_index == 0)` is a tripwire rather than a live check.
- **`src/gpu/metal/shader.zig:278-285`**: the test's comment currently asserts "**Not
  vacuous.** A test binary is a Debug build". Amend it to say that this holds in the Debug run
  and not in the other two, and that it is the reason `zig build test` stays.
- **`src/dsp/ring.zig:87-90` and `src/clap/state.zig:159-162`** both say "`zig build test`
  takes no `-Doptimize`, so it is a Debug build". Still true of `test`, now incomplete: name
  the two new steps as what closes the gap each docstring describes.
- **`src/gpu/measure.zig:74-75`** names `#94` in the future tense as intent; move it to what
  landed.
- **The verification-gaps plan**, section 6: mark landed, and record the three findings above
  plus the decision to add ReleaseSafe rather than refuse it.
- **The build plan's Verification table**, line 491: the `Unit tests` row currently reads
  "**Debug only** … #94 adds the mode that ships". Replace with the three modes.

## Acceptance

Three plants, each run against all three steps, each reverted afterwards. Commit before
planting so `git restore` cannot take the fix out with the plant.

**Plant 1 — the literal criterion: the refusal, not the safety check, is what holds in the
shipping build.** Delete `if (minimum_capacity == 0) return error.EmptyCapacity;`
(`ring.zig:114`). Its own docstring at `:83-91` names this asymmetry, and the downstream
assert is real: `std/math.zig:1219` is `assert(value != 0)` inside `ceilPowerOfTwoPromote`.
Expected, and to be recorded as measured rather than predicted:

- `zig build test` fails by **trapping** inside `std`'s own assert.
- `zig build test-release` fails by returning a **wrong error** — `error.Overflow` off a
  `usize` underflow — with no trap anywhere.
- Restored, all three steps pass and all three return `error.EmptyCapacity` from
  `ring.zig:396`.

**Plant 2 — the discriminating one, which is the only proof the new steps add coverage
rather than repeat it.** Move required work inside a `std.debug.assert` argument on a tested
pure path; `palette.buildPalette` (`palette.zig:243`) is the suggested site, since its table
is compared against a closed form at `palette.zig:716`. Expected: `zig build test` stays
**green**, `zig build test-release` goes **red** because the work was compiled out.
`test-safe` should stay green, which is the arm that shows ReleaseSafe is not a substitute
for ReleaseFast. This is the class of defect no Debug run can see, and it is also a second
positive control that the release step really is at ReleaseFast.

**Plant 3 — the vacuity, recorded rather than argued.** Drop `!builtin.is_test` from
`shader.live` (`shader.zig:45`). Expected: `zig build test` fails, `zig build test-release`
**passes**. That result is what belongs in the amended comment at `shader.zig:278` and in the
`AGENTS.md` bullet, and it is the executable form of "additive, never a replacement".

**Instrument check.** Plant `.ReleaseFast` → `.Debug` on the `test-release` call site and
confirm the comptime pin fails the build naming both modes. Without this, a future refactor
that dropped the pin would leave a green job testing Debug twice.

## Verification

```bash
zig build test && zig build test-safe && zig build test-release   # all three, 285/285 each
zig build test --summary all | grep 'compile test'                # says Debug
zig build test-safe --summary all | grep 'compile test'           # says ReleaseSafe
zig build test-release --summary all | grep 'compile test'        # says ReleaseFast
zig build                                                          # still produces only the .clap
zig fmt --check build.zig src/
```

Then the two checks that this change could break in ways the suite would not notice:

```bash
# The release-mode test binary must not carry a worktree path. Positive control first:
# the Debug one must carry it, or the grep proves nothing.
strings -a "$(find .zig-cache/o -name test -type f -perm +111 -newer build.zig | head -1)" \
  | grep -c "$PWD/shaders"

# The plain build is unchanged: nothing new on the default install step, and the
# configure-time cost of two extra dependency instances is what the comment claims.
time zig build --help > /dev/null
```

CI: push the branch, confirm `test-modes` goes green, read its duration from the Actions API,
set `timeout-minutes` from that measurement, and confirm the other eight jobs are unaffected.

## What this does not close

- **The watcher**, which is stubbed out in ReleaseFast for the same `shader.live` reason that
  stubs it in a test build. That is [#93](https://github.com/cboone/fosforo/issues/93).
- **`Editor.report`, the two render-thread assertions and the two `objc` thread assertions**
  (`gui.zig:819`, `renderer.zig:850`, `:868`, `objc.zig:62`, `:78`) are all
  `if (builtin.mode != .Debug) return;`, so the release steps exercise a *different* path
  through those five functions rather than a harder one. No coverage is lost today, since
  nothing tests them, but the release runs are not evidence about them either.
- **`src/smoke.zig`**, which is a separate executable outside all three test steps and follows
  the shared `optimize` as before.
- **Anything about the shipped bundle**, which is built by `cmake/CMakeLists.txt:101` at
  `--release=fast` and is not what these steps compile. What they share is the mode, not
  the artifact.
