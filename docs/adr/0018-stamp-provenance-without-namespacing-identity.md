# 0018. Stamp build provenance, and leave plugin identity alone

**Status:** Accepted

## Context

This repository is normally checked out as several worktrees on several branches, and all of them compete for one pair of directories under `~/Library/Audio/Plug-Ins/`. Building and installing are separate acts and only the second decides what a host loads, so the installed bundle belongs to whichever worktree copied last.

The resulting failure is silent and reads as a pass. A branch that added a resizable editor was once "verified" against an installed build whose `can_resize` returned false, where the window edge could not be dragged and nothing happening was the only available outcome. Verifying [#9](https://github.com/cboone/fosforo/issues/9) lost an hour to `auval`, code signing and cache invalidation before anyone compared the installed bytes against the ones just built. [#43](https://github.com/cboone/fosforo/issues/43) was a two-week-old Audio Unit from another branch that Logic loaded, rendered, and passed.

[Issue #22](https://github.com/cboone/fosforo/issues/22) frames this as two independent collisions, **path** and **identity**, and observes that fixing either alone is not enough. That framing is right about the general problem and worth separating from what has actually gone wrong here. Every incident on record is a path collision that went **unnoticed**. Two bundles claiming one `id` has never happened, because two bundles have never been installed at once.

Phase 3's remaining issues are all judged in a running host, so an ambiguous install is not a nuisance in this phase; it is the thing that invalidates the evidence.

## Decision

**Every build stamps the branch, commit and dirty state it came from, and nothing about the plugin's identity varies.**

`build.zig` asks git at configure time and passes three facts through `build_options`. `src/build_info.zig` composes the three strings anyone needs from them, and is the only place any of those formats is written down:

| Declaration          | Read by                                                       |
| -------------------- | ------------------------------------------------------------- |
| `marker`             | `scripts/read-provenance`; also logged, which keeps it live   |
| `descriptor_version` | the host, as the plugin's version                             |

```text
marker              fosforo-build: version=0.0.0 branch=chore/x commit=84bd70d dirty=no
descriptor_version  0.0.0+chore-x.84bd70d
```

A short `branch commit` form is deliberately absent. One was written and removed before merge: `scripts/read-provenance --short` already derives it from the marker, and a second declaration of that format in a second language is the duplication this module exists to prevent.

`scripts/read-provenance` is the one implementation of reading it back, and `scripts/install-plugins` uses it to say whose build is installed rather than only whether it is this one.

### What is deliberately not done

**The display name is not suffixed**, in any of its four locations. #22 proposes appending provenance to it for non-release builds, and the reason to refuse is that it helps least exactly where the problem is worst: `cmake/set-au-display-name` rewrites the Audio Unit's plist name from a hardcoded constant that CI asserts, so in Logic the name would read `Fósforo` whatever the descriptor said, and the Audio Unit is the half that goes stale. It would also cost the exact-equality assertion in `src/clap/plugin.zig`, an exception to the "change one, change all four" rule, and a release gate with nothing to enforce it. The version string carries the provenance instead, because it is the one host-visible field the build plan's identifiers section lists as free metadata.

**Identity is not namespaced.** No `-Dchannel=<slug>`, no per-worktree CLAP `id`, no `AUV2_SUBTYPE_CODE` hashed down to four characters. Those are #22's own "later, and only if" items, and the trigger it names — two worktrees' Audio Units genuinely needing to load at once — has not occurred. They also reach the identifiers the build plan marks permanent, which is the one category of change that cannot be undone after release.

**The Audio Unit is not installed as a symlink.** See the measurement below.

## Consequences

**A `git` invocation at configure time costs [ADR 0009](./0009-runtime-shader-compilation.md) nothing, and the precedent is stronger than the one `/usr/bin/codesign` sets.** That ADR's hermeticity claim is scoped to on-demand Xcode toolchain components and to the network. A plain `zig build` already spawns a subprocess before reaching the git call: `b.dependency("objc", ...)` runs zig-objc's build function at configure time, which calls `appleSDKPath` and so `std.zig.system.darwin.getSdk`, whose own comment reads "This executes `xcrun` to get the SDK path". Nothing here links Cocoa or Metal without the SDK that finds, so a working Xcode or Command Line Tools install is already a hard requirement. `git` is strictly weaker: it needs no network, and where `xcrun` failing is fatal, `git` failing lands on `unknown`. Verified by building a copy of the tree with no `.git`, which produces `branch=unknown commit=unknown` and no error.

**The build cache turns over on every commit.** The three option values feed the module's cache key, so the first build after a commit is a full rebuild and the dirty flag flips at most once per editing session. During active editing the values are stable, so this adds nothing on top of what editing already invalidates. In CI every run has a new commit, which lowers the Zig cache hit rate for the build steps.

**CI stamps `detached`, not a branch.** No checkout in `.github/` sets `fetch-depth`, so `actions/checkout` gives depth 1 with HEAD detached and `git rev-parse --abbrev-ref HEAD` returns the literal `HEAD`. On a `pull_request` the commit is the ephemeral merge rather than the branch head. This is correct rather than a limitation: a CI build is never installed anywhere, and the alternative is reading GitHub-specific environment variables into `build.zig`.

**The marker's survival is asserted rather than reasoned about.** It stays in the binary by being passed to `Log.print` from `plugin.init`, which is a claim about what the optimizer does. A build that stopped carrying it would leave every report reading `(no provenance)`, which looks exactly like a bundle predating the stamp. So CI runs `read-provenance --check` in both the `clap-validator` and `clap-wrapper` jobs. The second is the one that matters: `cmake/CMakeLists.txt` drives Zig with `--release=fast` where the other job builds Debug, and the two modes measurably differ — Debug emits `marker_prefix` as a separate literal beside the composed marker and ReleaseFast emits only the composed one. The reader therefore takes the longest match rather than the first.

### Two `git rev-parse` calls, not one

`git rev-parse --abbrev-ref HEAD --short HEAD` prints the branch name **twice**. `--abbrev-ref` is sticky across every ref that follows it, so the field meant to carry the commit silently carries the branch. A provenance line that is wrong while still looking well-formed is worse than one that is missing, and this is the failure mode a combined call produces.

### The symlinked Audio Unit, built and refused

The fourth bullet of #22 proposes pointing the shared Components directory at the active worktree, so `ls -l` answers which build is installed and switching costs one command. It was implemented and then removed, because **macOS does not register a symlinked component at all**.

The instrument is Logic's own scan log, `~/Library/Caches/AudioUnitCache/Logs/AUScan*.plist`, which names every Audio Unit it enumerated. Neither `auval` nor `AudioComponentFindNext` can see this component under any circumstances, so this is the only instrument available:

| Installed as | Audio Units | `Fósforo`  |
| ------------ | ----------- | ---------- |
| copy         | 60          | present    |
| **symlink**  | **59**      | **absent** |
| copy         | 60          | present    |

**The first attempt at this measurement was a false negative, and its own control caught it.** An earlier A/B pair read 59 for the symlink *and* 59 for the copy, because `AudioComponentRegistrar` had not settled after several rapid reinstalls. Waiting before relaunching Logic is what makes the reading stable. Without the control, "symlinks do not work" would have been recorded as a measurement while resting on an instrument that was answering the same way to everything.

`link_note` in `scripts/install-plugins` survives the refusal, and the refusal is what makes it worth having. A symlink made by hand produces a plugin that is silently missing from Logic, with no error anywhere and nothing wrong inside the bundle. That is precisely the class of failure this tooling exists to end, so it is now detected, explained, and repaired by an ordinary `zig build install-plugins`.

### `CLAP_PATH` relaxes the constraint for one of the two formats

`clap/entry.h` in the pinned SDK says a host **must** query `CLAP_PATH`, a `:`-separated list of directories searched recursively, **in addition to** the standard locations. Verified against REAPER 7.79: with the standard location empty, a CLAP in a worktree's `zig-out` is found, scanned and instantiated, and each instantiation prints its own provenance line naming that worktree.

With **both** present, REAPER loaded the `CLAP_PATH` copy and kept one cache entry. Do not rely on that: the specification says nothing about precedence, and REAPER caches CLAP bundles by filename with no path, so two bundles sharing `com.catamount.fosforo` are an ambiguity to avoid rather than one to reason about. Move the installed bundle aside first.

There is no equivalent for the Audio Unit. `AudioComponentRegistrar` scans only the two standard `Components` directories, there is no `AU_PATH`, and the symlink route above is closed. **So the install path stays exclusive for the Audio Unit and stops being exclusive for the CLAP**, which is a real change to the working order in the build plan's phase 3 section: a second stream can now run a CLAP in REAPER out of its own worktree while another owns the installed component.

### What is still not solved

Two worktrees still cannot load Audio Units simultaneously, and nothing here changes that. The stamp makes the collision visible rather than preventing it, which is the failure mode that has actually cost time. If simultaneous Audio Units are ever genuinely needed, the dev channel #22 describes is the design to reach for, and it needs a new ADR because it reaches identifiers this one deliberately leaves alone.
