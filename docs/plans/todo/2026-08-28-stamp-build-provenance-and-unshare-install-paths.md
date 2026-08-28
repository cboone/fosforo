# Stamp build provenance, and stop worktrees silently overwriting each other

Closes [#22](https://github.com/cboone/fosforo/issues/22).

## Context

This repository is normally checked out as several worktrees on several branches, and all of them compete for one pair of directories under `~/Library/Audio/Plug-Ins/`. Nothing connects a build to an install but a copy someone remembers to make, so the installed bundle belongs to whichever worktree copied last. The failure is silent and reads as a pass: a branch that added a resizable editor was once "verified" against an installed build whose `can_resize` returned false, where nothing happening was the only available outcome.

The issue names two independent collisions, **path** and **identity**, and observes that fixing either alone is not enough. It is right about that, and it is also true that only one of the two has actually cost anything. Every incident on record (#43, the two voided verification runs, the hour lost to `auval` and cache invalidation while verifying #9) is a *path* collision that went **unnoticed**, not an identity collision. Two bundles claiming one `id` has never happened here, because two bundles have never been installed at once.

So the ordering this plan takes is: make the ambiguity **visible** first, then remove the shared path where a format allows it, and leave identity namespacing unbuilt until something needs it. Concretely:

- A build stamps its own branch, commit and dirty state into the binary, and `scripts/install-plugins` reads that back out of what is **already installed**. That is the piece that answers "which worktree is loaded" for a bundle nobody in this worktree built, which is exactly the case where the existing `shasum` comparison compares against a file that does not exist.
- The CLAP stops needing the shared directory at all, via `CLAP_PATH`.
- The Audio Unit, which has no `CLAP_PATH` equivalent, gets an opt-in symlink install so the shared path at least *points* at a named worktree instead of holding an anonymous copy.

Phase 3's remaining issues are all judged in a running host, so this is prerequisite work rather than polish. The build plan puts #22 next for that reason.

## Decisions taken before writing this

**The display name is not suffixed.** The issue proposes appending provenance to the display name for non-release builds. Refused, and the reason is that it helps least exactly where the problem is worst: `cmake/set-au-display-name` rewrites the AU plist name from a hardcoded constant and CI asserts it with `--check`, so in Logic the name would read `Fósforo` whatever the descriptor said, and the Audio Unit is the half that goes stale. It would also cost an exact-equality assertion at `src/clap/plugin.zig:1164`, a release gate with nothing to enforce it, and an exception to the "the display name lives in four places, change one change all four" rule, all for a string that only REAPER would show. Provenance goes into `descriptor.version` (free metadata, per the plan's identifiers section), a `clap.log` line, and a greppable marker instead. Recorded as an ADR so it is not relitigated.

**Nothing about identity changes.** No dev channel, no per-worktree `id`, no hashed `AUV2_SUBTYPE_CODE`. Those are the issue's "later, and only if" bullets and the trigger it names (two worktrees' Audio Units genuinely needing to load simultaneously) has not occurred.

**`install-plugins` reports what it replaced; it never refuses.** Matches the script's existing stance on the stale-component report: "a report and not an error, because the CLAP-only loop is the common one."

## Two findings that change the shape of the work

**A configure-time subprocess already exists, so `git` in `build.zig` is not a new dependency class.** ADR 0009's hermeticity is scoped to Xcode toolchain *components* and to the network, and the worry here was that shelling out to `git` breaks it. It does not, and the evidence is stronger than an argument by analogy to `/usr/bin/codesign`: `b.dependency("objc", ...)` runs zig-objc's `build()` at configure time, which calls `appleSDKPath` → `std.zig.system.darwin.getSdk`, whose own comment reads "This executes `xcrun` to get the SDK path." A plain `zig build` therefore already runs a subprocess and already hard-requires a valid Xcode/CLT installation, because it cannot link Cocoa or Metal without the SDK that call finds. `git` is strictly weaker than that: it needs no network, and unlike `xcrun` it degrades to a fallback value instead of failing the build.

**CI checks out shallow and detached, so the branch name is not available there.** `fetch-depth` appears nowhere in this repository, so `actions/checkout@v4` gives depth 1 with HEAD detached. `git rev-parse --abbrev-ref HEAD` returns the literal `HEAD`, there are no tags, and on `pull_request` the checked-out SHA is the ephemeral merge commit rather than the PR head. This is fine (a CI build is never installed anywhere) but the format has to accommodate it rather than emit `HEAD` as a branch name.

## What changes

### 1. `build.zig`: compute provenance once, at configure time

Add a `Provenance` struct and a `gitProvenance(b)` function, called **after** the `if (target.result.os.tag != .macos) return;` early return at `build.zig:35`, so the Linux `ring-race` path pays nothing. Store it on `Core` (`build.zig:143`) and emit three options from `Core.module` (`build.zig:162-165`), beside the existing `export_entry` and `version`:

```zig
build_options.addOption([:0]const u8, "git_branch", self.provenance.branch);
build_options.addOption([:0]const u8, "git_commit", self.provenance.commit);
build_options.addOption(bool, "git_dirty", self.provenance.dirty);
```

`Options.addOption` emits a `[:0]const u8` as a Zig string literal via `fmtString`, so a runtime-computed value works; allocate with `b.allocator.dupeZ` after trimming.

Use `b.runAllowFail(argv, &code, .ignore)` rather than `b.run`, because `b.run` calls `process.fatal` and a tree with no `.git` must degrade rather than fail. `.ignore` on stderr keeps git's `fatal: not a git repository` off the terminal. Pass `-C <build_root>` explicitly rather than relying on the build runner's cwd, and name the binary `/usr/bin/git` by absolute path, on the precedent `build.zig:277-282` sets for `/usr/bin/codesign`.

**Three details that are load-bearing:**

- **Two `git` calls, not one.** `git rev-parse --abbrev-ref HEAD --short HEAD` prints the branch name *twice*: `--abbrev-ref` is sticky across the refs that follow it, so the second field would silently be the branch rather than the SHA. Measured, not assumed. Use `rev-parse --abbrev-ref HEAD` and `rev-parse --short HEAD` separately.
- **Fall back to `unknown`, and map detached HEAD to `detached`.** A tarball built from `build.zig.zon`'s `.paths` has no `.git` (it lists `src`, `shaders`, `cmake`, `scripts` and three files, and no `.git`), and CI is detached. Neither is an error.
- **Dirty is `git status --porcelain` being empty.** It respects `.gitignore`, so `zig-out/` and `build/` do not register.

**Known cost, worth stating rather than discovering:** the option values feed the module's cache key, so the first `zig build` after each commit is a full rebuild, and the dirty flag flips once per editing session. During active editing the values are stable, so this adds nothing on top of what editing already invalidates. In CI every run has a new SHA, which lowers the Zig cache hit rate for the build steps.

### 2. `src/build_info.zig` (new): compose the three strings

One small module owning the formats, so no consumer restates one. It reads `build_options` and exposes:

| Declaration          | Value                                                                 | Consumer                                               |
| -------------------- | --------------------------------------------------------------------- | ------------------------------------------------------ |
| `marker_prefix`      | `"fosforo-build: "`                                                   | the grep anchor, and the test below                    |
| `marker`             | `fosforo-build: version=0.0.0 branch=chore/x commit=84bd70d dirty=no` | logged at init; read back by `scripts/read-provenance` |
| `descriptor_version` | `0.0.0+chore-x.84bd70d` (`.dirty` appended when dirty)                | `descriptor.version`                                   |
| `summary`            | `chore/x 84bd70d`                                                     | the `clap.log` line and the smoke harness banner       |

`descriptor_version` sanitizes the branch by replacing anything outside `[0-9A-Za-z-]` with `-`, so a branch with a `/` still yields valid semver build metadata. `marker` keeps the branch verbatim, because it is free text read by humans and by one script. That asymmetry is deliberate and gets a comment.

The unknown case is `0.0.0+unknown`; the CI case is `0.0.0+detached.<sha>`.

### 3. `src/clap/plugin.zig`: carry it, and say it once per instance

- `descriptor.version` (`plugin.zig:52`) takes `build_info.descriptor_version.ptr` instead of `build_options.version.ptr`. The existing test at `plugin.zig:1167` asserts only non-emptiness, so it still passes; add one asserting the string still *starts with* `build_options.version`, so the base version stays readable.
- In `init` (`plugin.zig:221-252`), immediately after `self.log = log.Log.init(self.host);`, emit the provenance line. Use `CLAP_LOG_INFO` rather than the `CLAP_LOG_DEBUG` the neighbouring lifecycle messages use: the `stderr` mirror is compiled out of a release build (`log.zig:109`), so the host channel is the only carrier there, and this is the one message whose value is highest in a build you are merely holding.
- `plugin.zig:1164` and `cmake/set-au-display-name` are **untouched**; both keep asserting `Fósforo` exactly.

**Why the marker survives the optimizer.** It is passed as a runtime `{s}` argument to `log.print` from `init`, which is reachable from the factory, so it is live in every mode. `descriptor_version` is separately live as a comptime field of a static struct returned by `get_plugin_descriptor`. Two independent carriers, and the CI assertion in item 6 is what makes that a checked claim rather than a reasoned one.

### 4. `scripts/read-provenance` (new): the one implementation of reading it back

Takes a bundle directory or a Mach-O and prints the marker line. `--check` asserts a well-formed marker is present and exits non-zero otherwise. Follows the house shape of `scripts/assert-adhoc-signature`: warn per violation, distinct exit codes for "absent" versus "malformed", `E_USAGE=64` / `E_DATAERR=65` / `E_NOINPUT=66`.

Extraction is `LC_ALL=C /usr/bin/grep -a -o 'fosforo-build: [^[:cntrl:]]*'`, which needs no Xcode component. Verified against the currently installed binary: the same pattern shape returned `A GPU-rendered phosphor oscilloscope.` exactly, terminating at the NUL with no bleed from adjacent literals. `strings` is deliberately not used, since `/usr/bin/strings` is an `xcrun` shim.

Add it to the `[cmake/narrow-au-resource-usage]`-style per-file sections in `.editorconfig`, which is required rather than optional: the `shell` job selects by shebang and would lint it immediately, while `.editorconfig` styles it only once listed, and the resulting failure is `shfmt` reporting tabs against a file that matches its siblings.

### 5. `scripts/install-plugins`: report provenance, and say what was replaced

Four changes, all inside the existing structure:

- A `provenance()` helper delegating to `scripts/read-provenance`, printing `(no provenance)` rather than failing, so a bundle predating this change is described rather than fatal.
- `install_bundle` reads the **outgoing** bundle's provenance before `rm -rf` and prints it beside the incoming one. This is the line that names the worktree that just lost the install path.
- `describe_installed` prints provenance next to the hash and mtime. This is the highest-value line in the change: it is the "NOT from this build" path, where the hash has nothing to compare against, and it is the exact case #43 missed.
- A `--symlink-audio-unit` mode (see item 7).

### 6. CI: assert the marker survives, in both jobs

Add a `read-provenance --check` step to the `clap-validator` job for `zig-out/Fosforo.clap`, and to the `clap-wrapper` job for `build/assets/Fosforo.clap` and `build/assets/Fosforo.component`.

Asserted twice on the precedent at `ci.yml:598-601` ("the two jobs build through different systems... so either one can leak without the other"), and here the second is the one that matters most: the component's Zig half is built by `cmake/CMakeLists.txt:101` with `--release=fast`, a different optimize mode from anything the first job builds, which is precisely where dead-code elimination could drop a string the Debug build keeps.

The added step is a `grep`, so no `timeout-minutes` needs re-measuring; neither job is the one #63 took from 2.7x to 1.5x.

### 7. The Audio Unit: an opt-in symlink install

`scripts/install-plugins --symlink-audio-unit` replaces the component copy with a symlink from `~/Library/Audio/Plug-Ins/Components/Fosforo.component` to `<worktree>/build/assets/Fosforo.component`, forwarded from `build.zig` as `-Dsymlink-audio-unit` on the exact pattern `-Dleak-cycles` already uses at `build.zig:405-407`.

It does not let two worktrees load at once, and it does not remove staleness; it changes staleness from "another branch's component, anonymous" into "this worktree's component, possibly not rebuilt", which the provenance line and the mtime both make legible. `ls -l` answers the ownership question directly.

The script must report, rather than assume, three states the copy path cannot reach: that the installed component **is** a link, where it points, and whether that target still exists (a `rm -rf build` leaves it dangling). The hash comparison is vacuous through a link, so it is replaced by the link report rather than printed as a meaningless match. `rm -rf` on the link removes the link and not the target, which is worth a comment next to it.

**This item is gated on measurement.** `auval` and `AudioComponentFindNext` cannot see this component at all, so Logic is the only instrument. If Logic does not register a symlinked component, the mode is dropped and the refusal is recorded in the ADR rather than worked around.

### 8. `CLAP_PATH`: verify, then document

No code change. `clap/entry.h` in the pinned SDK says a host "must query the environment for a `CLAP_PATH` variable", **additive** to the standard directories rather than replacing them, so the installed bundle has to be moved aside first or the host sees two plugins sharing `com.catamount.fosforo`, with unspecified behaviour.

Two things to establish and write down:

- The issue's suggested `CLAP_PATH="$PWD/zig-out" open -a REAPER` is the wrong shape: apps launched through LaunchServices do not inherit the calling shell's environment. Launch the binary directly, which is what AGENTS.md already prescribes for reading diagnostics anyway: `CLAP_PATH="$PWD/zig-out" /Applications/REAPER.app/Contents/MacOS/REAPER`. Confirm both forms so the documented one is the measured one.
- What REAPER does with both bundles present, since that is the state anyone will hit by accident.

### 9. Documentation

- **`docs/adr/0018-stamp-build-provenance-without-namespacing-identity.md`** (new). Records the decision, the display-name refusal and its Logic reasoning, the identity-namespacing deferral, the `xcrun` precedent that settles the ADR 0009 question, and whatever item 7's measurement returns.
- **`AGENTS.md`**: extend the provenance gotcha (L164-179) with the readback and `CLAP_PATH`; add `scripts/read-provenance` and `src/build_info.zig` to the structure listing; add the commands; add a gotcha for the two `git rev-parse` calls and for CI's detached HEAD.
- **`docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`**: close #22 in the phase-2 chores table (L267) and advance the working order (L337).
- **`README.md:47`** and **`CONTRIBUTING.md:48-53`** restate the hazard; update the one sentence each that now has a better answer.

## Verification

Ordered so the cheap checks fail first, and so the two exclusive resources (the install path with a host, the GPU with a window server) are each held once.

**Static and unit:**

1. `zig build test`, `zig fmt --check build.zig src/`
2. `git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d` and the same piped to `shellcheck` (bare `shfmt`, no parser or printer options, or `.editorconfig` is discarded)
3. `typos`
4. A new test in `src/build_info.zig` reading `scripts/read-provenance` as text and asserting its grep pattern contains `marker_prefix`, on the precedent of the `measure-trace` test in `src/gpu/metal/renderer.zig` and wired through `addTestStep`'s test-module-only anonymous import (`build.zig:330-332`)

**The marker actually survives, in both modes:**

1. `zig build && ./scripts/read-provenance --check zig-out/Fosforo.clap`
2. `zig build --release=fast && ./scripts/read-provenance --check zig-out/Fosforo.clap`
3. `zig build audio-unit && ./scripts/read-provenance --check build/assets/Fosforo.component`
4. Confirm the reported branch and SHA match `git rev-parse`, and that touching a tracked file flips `dirty=no` to `dirty=yes`
5. Confirm the fallback: run the extraction against a checkout with no `.git` reachable, or temporarily point `-C` at a non-repo, and confirm `unknown` rather than a build failure

**The end-to-end case the issue was filed for** (needs the install path; the other worktree at `/Users/ctm/Development/fosforo` is the second party):

1. `zig build install-plugins` here, and read the report
2. From the `main` worktree, `zig build install-clap`
3. Back here, `zig build install-plugins`, and confirm the report names `main` as what it replaced. This is the whole issue in one line of output, and it is the check that would have saved the hour spent verifying #9.

**In a host** (needs REAPER, then Logic, exclusively):

1. `clap-validator validate zig-out/Fosforo.clap`, and confirm the version field now carries provenance and the name is still `Fósforo`
2. Launch REAPER from a terminal; confirm the `fosforo-build:` line appears, that the FX browser still reads `Fósforo`, and that the trace renders
3. Move the installed CLAP aside, relaunch REAPER with `CLAP_PATH` pointing at `zig-out`, rescan, and confirm it loads the worktree bundle; then restore the installed one and record what REAPER does with both
4. `scripts/install-plugins --symlink-audio-unit`, relaunch Logic, confirm the component registers and renders, and confirm the script reports the link and its target. If it does not register, drop item 7 and record why
5. `ls -l ~/Library/Audio/Plug-Ins/Components/Fosforo.component` answers the ownership question without running anything

**The GPU and window server:**

1. `zig build smoke-gpu`, `zig build smoke-appkit`, and confirm the harness banner prints the build line

## Out of scope, deliberately

- Any change to the CLAP `id`, the AU triple, `CFBundleIdentifier`, or the display name in any of its four locations
- A `-Dchannel=<slug>` dev channel and the hashed `AUV2_SUBTYPE_CODE` it would need; the issue's own trigger for it has not occurred
- Arguments to `cmake/set-au-display-name`, which the issue flags as the tradeoff a dev channel would invert; leaving the display name alone is what keeps that script a CI one-liner
- A dirty-tree refusal in `scripts/build-release-bundles`. It reports provenance for the record, and does not gate on it: the release path is not exercised by CI and can rot (ADR 0014), so new refusals there are untested surface
- Symlinking the CLAP, which `CLAP_PATH` answers better by not sharing a path at all
