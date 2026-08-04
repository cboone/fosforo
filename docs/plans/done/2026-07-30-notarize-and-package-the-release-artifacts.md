# Notarize and package the release artifacts

Closes [#24](https://github.com/cboone/fosforo/issues/24). Branch: `chore/notarize-builds`.

## Context

[#20](https://github.com/cboone/fosforo/issues/20) gave every bundle the build produces an ad-hoc bundle signature, which is exactly enough to pass `codesign --verify` and deliberately not enough to distribute. It left two identity switches (`zig build -Dcodesign-identity=`, `cmake -DFOSFORO_CODESIGN_IDENTITY=`) and stopped, because an identity is one of four things a distributable signature needs.

Issue #24 declared itself blocked on three things. This plan clears all three:

| Blocker                                     | State at the start of this plan                                                                                   | Resolution                                                                             |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| A Developer ID certificate                  | Absent. `security find-identity -v -p codesigning` finds only `Apple Development: Christopher Boone (U33UQ83W5V)` | Issue one from the existing paid membership. Prerequisites section below               |
| A release process                           | Absent. `build.zig.zon` is `0.0.0`, `CHANGELOG.md` has only `[Unreleased]`                                        | Three scripts under `scripts/`, run locally. No version bump: see **Out of scope**     |
| A decision about what a release artifact is | Undecided. Up to three bundles land in three directories                                                          | A signed, notarized `.pkg` with a user-selectable install domain. Recorded as ADR 0013 |

The outcome is a repeatable local path from a clean checkout to a notarized `Fosforo.pkg` that a stranger can download and double-click without Gatekeeper refusing it, plus a documented answer to the hardened-runtime question the issue raises but does not settle.

## Status

Everything reachable without a Developer ID certificate is built and verified. What remains is gated on the certificate itself, which needs interactive Apple authentication and cannot be scripted.

| Step                                               | State                                                                                       |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| A1 conditional `--timestamp` / `--options runtime` | Done. Verified in both directions against the Apple Development certificate                 |
| A2 CI guard on the ad-hoc path                     | Done. `scripts/assert-adhoc-signature`, wired into both jobs, tested pass and fail          |
| B hardened runtime and entitlements                | Done. Answer is no entitlements, established mechanistically rather than by one observation |
| C1 ADR 0013                                        | Done                                                                                        |
| C2 `build-release-bundles`                         | Done. Fails on the authority alone, which is correct without a Developer ID certificate     |
| C3 `build-installer`                               | Done. Payload paths and the home install domain verified against a real package             |
| C4 `notarize-installer`                            | Done. Accepted by Apple on the first submission                                             |
| C5 documentation                                   | Done                                                                                        |
| Final Gatekeeper verification                      | Done. Also loaded in REAPER and Logic                                                       |

Measured on 2026-07-30, ad-hoc path restored afterwards: `zig fmt --check` clean, `zig build test` passing, `clap-validator` 44 run / 21 passed / 0 failed, all three bundles ad-hoc and `codesign --verify --strict` clean, both AU plist invariants holding, `actionlint` clean, `shfmt -d` and `shellcheck` clean.

### The release path, run end to end on 2026-08-04

Certificates issued under team `UAM22D2F3S`, both expiring 2027-02-01, six months out rather than the usual five years. Xcode issued them under the G1 intermediate, which expires at that same instant, and Apple caps a leaf's validity at its issuer's. Tracked as issue [#30](https://github.com/cboone/fosforo/issues/30); it does not affect anything signed here, because a secure timestamp keeps a signature valid past its certificate's expiry, which is why `--timestamp` is mandatory rather than optional.

| Check                                      | Result                                                                          |
| ------------------------------------------ | ------------------------------------------------------------------------------- |
| `security find-identity -v -p codesigning` | Lists Application, omits Installer. The documented trap, now measured           |
| `build-release-bundles`                    | Both bundles `flags=0x10000(runtime)`, timestamped, Developer ID authority      |
| Shipped CLAP is ReleaseFast                | `hashes=6+3`, against `hashes=123+3` for the Debug build                        |
| `build-installer`                          | `dist/Fosforo-0.0.0.pkg`, 370K, `productbuild` timestamped the signature itself |
| Gatekeeper **before** notarizing           | `rejected`, `source=Unnotarized Developer ID`, exit 3                           |
| `notarytool submit --wait`                 | `934427f0-61a2-407e-b526-7c785d83f202`: **Accepted**, first attempt             |
| Gatekeeper **after** stapling              | `accepted`, `source=Notarized Developer ID`                                     |
| Assessed with `com.apple.quarantine` set   | `accepted`, `source=Notarized Developer ID`                                     |
| `stapler validate`, never-stapled control  | Exit 66                                                                         |
| `stapler validate`, stapled and moved      | Exit 0, so the ticket is embedded in the file rather than tied to its path      |
| Downloaded in a browser                    | Safari set `com.apple.quarantine` = `0083;6a720dbb;Safari Technology Preview;…` |
| That downloaded copy assessed              | `accepted`, `source=Notarized Developer ID`                                     |
| Installed from it, home domain             | Both bundles placed, Developer ID signed, hardened runtime                      |

The before-and-after Gatekeeper pair is the load-bearing one: it makes the change attributable to notarization rather than to anything else about the package.

The browser download is the only row that tests what a user actually experiences. Every row above it was assessed against a file that had never carried `com.apple.quarantine`, which is a weaker claim than it looks. Confirming the attribute was genuinely set, before reading the assessment, is what makes the result mean anything.

### Loaded in both hosts

The last empirical gap, closed by hand because it needs a GUI host.

- **REAPER, the CLAP.** Loads and runs. No `clap.log` output, which is correct rather than a symptom: `src/clap/log.zig:109` gates the `stderr` mirror to Debug builds, and this is a ReleaseFast bundle from the package. REAPER separately accepts `clap.log` messages and discards them, so a release build has no diagnostic destination at all.
- **Logic, the Audio Unit.** Loads, validates with a green Compatibility check in the Plug-in Manager, and opens its editor.

Both render the dim background and nothing else, which is what this phase draws: `shaders/scope.metal` is a placeholder whose `clear_fragment` returns `float4(0.02, 0.02, 0.03, 1.0)`, and the trace passes arrive in phase 3. The editor is fixed-size because the resize seam is [#5](https://github.com/cboone/fosforo/issues/5).

**That the editor appeared at all is the result.** `renderer.zig` builds its pipeline with `try buildPipeline(...)` and `gui.zig` creates the editor with `try gpu.Renderer.init(...)`, so a shader that failed to compile would fail editor creation rather than draw a blank frame. A drawn frame therefore means `newLibraryWithSource:` compiled the shader at runtime inside Logic's sandboxed `AUHostingServiceXPC`, from a Developer ID signed, hardened-runtime bundle carrying no entitlements. That is the phase B conclusion confirmed in the strictest host available, rather than only reasoned about.

One diagnostic caveat worth knowing before relying on this again: the clear colour and the fragment shader's output are deliberately identical, so the picture cannot distinguish "the shader ran" from "only the clear ran". The proof is structural, not visual.

### A false alarm worth recording

The Audio Unit appeared to have vanished from Logic's Audio FX menu. It had not. Logic filters that menu by the channel strip's format, and the plugin declares exactly one configuration, `[[2, 2]]`, stereo in and stereo out (`src/clap/plugin.zig:623`). On a mono track it is correctly not offered, and every other unit in that menu was mono too. Dropping a stereo file onto the track changed its format and the plugin appeared.

Nothing about signing, packaging or notarization was involved, and a good deal of diagnosis went into the wrong half of the system before the channel format was checked. Two instruments misled along the way and are worth distrusting next time: `log show` returns nothing at all here without Full Disk Access, so a null result from it means nothing, and Logic's tagset filenames are hex-encoded (`aufx/Fsfr/Ctmn` is `61756678-46736672-43746d6e.tagset`), so grepping them for a plugin name silently finds nothing.

## Decisions taken

Settled in conversation. Inputs to the plan, not open questions.

- **The artifact is a `.pkg`.** Two bundles belonging in two different directories is the case installers exist for, and `notarytool` accepts a pkg directly while `stapler` can staple it as a single file, neither of which is true of a bare bundle.
- **The user chooses the install domain.** A distribution XML offering both the local system and the current user's home, rather than forcing an admin password.
- **Signing and notarization run locally, never in CI.** The repository is public. Exporting a Developer ID private key and an App Store Connect key into repository secrets buys hands-off releases at the cost of putting distribution-grade credentials where a workflow-file mistake can read them. Releases are rare and manual; CI keeps signing ad-hoc and offline exactly as it does today.
- **The version stays `0.0.0`.** This branch builds and exercises the machinery on a real test artifact. Cutting v0.1.0 stays a Phase 6 decision, per [the build plan](2026-07-25-repo-foundation-and-phased-build-plan.md).
- **The shipped CLAP is the Zig-built one.** `zig build` produces the native artifact and that is the day-to-day loop; the CMake build's CLAP exists so CI can prove the clap-wrapper seam works (ADR 0003). The pkg takes `zig-out/Fosforo.clap` and `build/assets/Fosforo.component`, and discards `build/assets/Fosforo.clap`.

## Prerequisites, performed by hand

None of this can be scripted: every step needs interactive Apple authentication. These gate phase A and everything after it, but not phase B.

1. **Issue a Developer ID Application certificate.** Xcode > Settings > Accounts > Manage Certificates > **+** > Developer ID Application. Verify: `security find-identity -v -p codesigning` now lists `Developer ID Application: … (TEAMID)` alongside the Apple Development one.
2. **Issue a Developer ID Installer certificate.** Same panel. **Verify it differently:** the `codesigning` policy does not match installer certificates, so `-p codesigning` will not list it and a null result there is not evidence of failure. Use `security find-identity -v` with no policy, and confirm the Application certificate appears in the same output as a positive control.
3. **Create an App Store Connect API key.** App Store Connect > Users and Access > Integrations > Keys, role Developer. Download the `.p8` once; it is unavailable afterwards. Note the Key ID and Issuer ID. Preferred over an app-specific password: scoped, independently revocable, not tied to the Apple ID password.
4. **Store the notary credentials in a keychain profile.** `xcrun notarytool store-credentials "fosforo-notary" --key ~/…/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer XXXXXXXX-…`, with the `.p8` kept outside the repository. Verify: `xcrun notarytool history --keychain-profile "fosforo-notary"` returns without an auth error.

## Phase A: teach the existing signing commands to produce a distributable signature

Independent of phase B and safe to do in either order or concurrently.

### A1: conditional `--timestamp` and `--options runtime`

Two call sites, one rule: when the identity is not `-`, add both flags; when it is `-`, add neither, so a plain build stays offline and hermetic (ADR 0009). `--timestamp` contacts Apple's timestamp server and is meaningless for an ad-hoc signature.

- `build.zig`, in `signClapBundle` (currently around line 181): append the flags with `addArgs` when the identity is not `-`. They must land before `addDirectoryArg`, because the bundle path is positional and `codesign` wants it last.
- `cmake/CMakeLists.txt`, in `fosforo_sign_bundle` (currently around line 227): a `FOSFORO_CODESIGN_FLAGS` list beside the existing `FOSFORO_CODESIGN_IDENTITY` cache variable, expanded inside the `COMMAND`. An empty CMake list expands to nothing under `VERBATIM`, leaving the ad-hoc path byte-identical.
- Update the comment blocks above both, which currently name #24 as unfinished work, and the corresponding `AGENTS.md` gotcha, which ends the same way.

**Checks, both scriptable:**

```bash
# Ad-hoc path, offline: must be unchanged.
zig build && cmake --build build --target fosforo_all
codesign -dvv zig-out/Fosforo.clap 2>&1 | grep -q 'flags=0x2(adhoc)'
codesign -dvv zig-out/Fosforo.clap 2>&1 | grep -qv 'Timestamp='

# Identity path: runtime hardened, timestamped, Developer ID authority.
zig build -Dcodesign-identity="Developer ID Application: …"
codesign -dvv zig-out/Fosforo.clap 2>&1 | grep -q 'flags=0x10000(runtime)'
```

### A2: pin the ad-hoc path in CI

The conditional above is the kind of thing that leaks silently: a future edit that always appends the flags still passes `codesign --verify`, and the first symptom is a CI job hanging on a timestamp server it cannot reach. Extend the two existing assertions (`Assert the CLAP is signed`, line 231, and `Assert the wrapper artifacts are signed`, line 334) to also assert `flags=0x2(adhoc)` and the absence of a `Timestamp=` line.

This is the only part of the release path CI can guard, since CI has no certificate, and it is worth having for exactly that reason. Verified by the push itself.

**Commits:** A1 and A2 separately. A1 carries its own comment and `AGENTS.md` changes; A2 is a CI-only change.

## Phase B: answer the hardened-runtime question empirically

Independent of phase A: the experiment signs a bundle by hand rather than through the build, so it needs neither A1 nor a rebuild.

The issue asks whether runtime Metal shader compilation needs `com.apple.security.cs.allow-jit` or an `allow-unsigned-executable-memory` entitlement, and insists it be answered by testing rather than by adding entitlements speculatively. Reconnaissance suggests the answer is no, for a structural reason worth confirming and then writing down: **a plugin never gets a process of its own, so its own entitlements are inert.** The host's govern. `/Applications/REAPER.app` already carries `allow-jit`, `allow-unsigned-executable-memory` and `disable-library-validation`, and that last one is what permits loading a bundle signed by another team at all.

1. Sign an existing build by hand, with no entitlements:
   `/usr/bin/codesign --force --sign "Developer ID Application: …" --timestamp --options runtime zig-out/Fosforo.clap`
2. Assert the shape programmatically: `codesign -dvv` reports `flags=0x10000(runtime)` and a `Timestamp=`, and `codesign -d --entitlements -` prints nothing.
3. `zig build install-clap`, then launch REAPER **from a terminal** so `clap.log` output is visible (see the `AGENTS.md` gotcha), open the GUI, confirm the trace renders and no shader compilation error appears. Irreducibly manual: it needs a GUI host.
4. Repeat for the Audio Unit in Logic, via `cmake --build build --target fosforo_all`.
5. **Only on failure**, add `packaging/entitlements.plist` with `com.apple.security.cs.allow-jit` alone, retest, and add `allow-unsigned-executable-memory` only if that is still insufficient. Narrowest set that works, one entitlement at a time, and it becomes a `--entitlements` argument at both signing call sites.

**Commit:** the finding written into `AGENTS.md`, whichever way it goes. A confirmed "no entitlements needed" is a result, not an absence of one, and it is the thing that stops this being re-derived later.

## Phase C: the installer

The main work. Each commit lands its own housekeeping and its own documentation; none of it is deferred to a cleanup pass.

### C1: ADR 0013

`docs/adr/0013-distribute-as-a-notarized-pkg.md`, in the shape of the existing ADRs, plus its row in the table in `docs/adr/README.md`. Records the pkg choice over a dmg or per-format zips, the user-selectable domain, and the deliberate exclusion of distribution signing from CI. The decision record precedes the code implementing it.

### C2: signed bundles, on demand

- `packaging/distribution.xml`: `<domains enable_anywhere="false" enable_localSystem="true" enable_currentUserHome="true"/>`, the two `<pkg-ref>` entries, and the title. Component install locations are written as `/Library/Audio/Plug-Ins/CLAP` and `/Library/Audio/Plug-Ins/Components`; in the home domain the installer reinterprets them relative to the user's home, which is the mechanism that lets one distribution serve both choices and is the part most likely to need adjusting against a real run.
- `scripts/build-release-bundles`: runs `zig build` and `cmake --build … --target fosforo_all` with the Developer ID Application identity, read from the environment so no credential is ever a committed default or a shell-history argument. Refuses to run with the identity unset rather than silently producing an ad-hoc build.
- **The script asserts its own postconditions** and exits non-zero: every output bundle reports `flags=0x10000(runtime)`, carries a `Timestamp=`, names a Developer ID authority, and passes `codesign --verify --strict`. That is what makes this stage self-testing rather than eyeballed.

Housekeeping this commit requires, because each is a documented trap here:

- `.editorconfig`: add the script to the `[{*.sh,*.bash,narrow-au-resource-usage,set-au-display-name}]` section. The `shell` CI job finds files by shebang and lints a new script immediately, while `.editorconfig` styles it only once listed, and the asymmetry shows up as `shfmt` rejecting a file that matches its siblings exactly.
- `.gitignore`: add `*.p8`, which the secrets block omits while covering `*.pem`, `*.key` and `*.p12`, plus the scripts' output directory.
- Invoke the `write-bash-scripts` skill before writing, and verify with the repository's own incantation, no parser or printer options: `git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d`, and the same pipeline through `shellcheck`.

### C3: the pkg

`scripts/build-installer`: `pkgbuild --component` once per bundle into a staging directory, then `productbuild --distribution packaging/distribution.xml --package-path … --sign "Developer ID Installer: …"`. Same environment-variable handling, same `.editorconfig` and lint steps.

Two assertions belong in this script rather than in a checklist:

- **Version agreement.** `build.zig.zon` and both version keys in `macos/Info.plist` say `0.0.0` independently, and the Audio Unit's version comes from CMake. The script refuses to package a mismatch, rather than adding a fourth place to forget.
- **Payload paths.** `pkgutil --expand-full` into a temporary directory and assert the two bundles appear at the expected relative locations, so a distribution XML edit cannot quietly reroute them.

**Checks:** `installer -pkg … -target CurrentUserHomeDirectory` and `-target /`, confirming each lands both bundles correctly and a host loads them from there. Then `spctl --assess --type install` on the unnotarized pkg, which should **reject** it: a positive control proving the assessment in C4 is measuring something.

### C4: notarize and staple

`scripts/notarize-installer`: `xcrun notarytool submit --keychain-profile "fosforo-notary" --wait`, then `xcrun stapler staple`, then `xcrun stapler validate` and `spctl --assess --type install --verbose=4`, asserting `source=Notarized Developer ID`.

Separate from C3 because notarization is slow and network-bound: a failed staple should not force a rebuild, and the two signing identities have genuinely different failure modes. On rejection, `xcrun notarytool log <id>` returns a JSON report naming the offending path and rule.

Only the pkg is submitted, not the bundles individually. Files laid down by an installer do not receive `com.apple.quarantine`, so the pkg's stapled ticket is the one Gatekeeper consults. If the final verification contradicts that, the fallback is a first notarization round over a zip of the two bundles, stapling each before packaging.

### C5: the release path, documented

`AGENTS.md` gains the three commands in the Development section and a gotcha covering what cost time to establish: that `-p codesigning` does not list installer certificates, why only the pkg is stapled, and the domain-reinterpretation behaviour. `CHANGELOG.md` gains its `[Unreleased]` > `Added` entry.

## Final verification: Gatekeeper, on a file that was not built here

The last checklist item in the issue, and the only check that answers the question a user actually faces. `spctl --assess` locally is a weaker claim than it looks, because a locally built file never carried `com.apple.quarantine`.

1. Upload the pkg to a **draft** GitHub release.
2. Download it **in a browser**. `curl` does not set the quarantine attribute and cannot substitute.
3. `xattr -p com.apple.quarantine Fosforo.pkg` returns a value. If it does not, the test is invalid and nothing below it means anything.
4. `spctl --assess --type install --verbose=4` reports `accepted, source=Notarized Developer ID`, then double-click and confirm the installer opens with no Gatekeeper interception.
5. `xcrun stapler validate` with networking off, since surviving offline is the entire point of stapling.

**Commit:** the measured result recorded in the plan, the way `docs/plans/done/2026-07-29-tighten-ci-job-timeouts.md` records its measurements. Then move this plan to `docs/plans/done/`.

## What testing found that planning did not

Three things, each now encoded in a script or in `AGENTS.md` rather than only recorded here.

- **`cmake --build` clobbers the Zig-built CLAP.** `cmake/CMakeLists.txt` drives Zig through an `ALL` custom target running a bare `zig build --release=fast`, which reassembles and ad-hoc re-signs `zig-out/Fosforo.clap`. Building the CLAP first therefore signs it correctly and then throws that away. `build-release-bundles` builds the Audio Unit first for this reason.
- **A plain `zig build` is Debug.** `standardOptimizeOption` declares no default, while everything CMake triggers is ReleaseFast, so the two paths disagree about optimize mode. A shipped CLAP must name `--release=fast` explicitly.
- **Packaging trusted its inputs, and that shipped the wrong bundle.** The first working package contained a stale Debug, ad-hoc CLAP, because `pkgbuild` packages whatever is on disk and nothing had checked provenance. `build-installer` now asserts both bundles will notarize before packaging them. This was observed, not anticipated, and it is the single most valuable thing this testing turned up.

## Risks

| Risk                                                                         | Mitigation                                                                                                       |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `enable_currentUserHome` domain handling has long-standing quirks            | C3 tests both domains explicitly. Fallback is system-only, which is what nearly every audio installer ships      |
| Notarization rejects the submission for a reason local checks cannot predict | `notarytool log <id>` names the offending path and rule. C4 is a separate script so retrying costs no rebuild    |
| Stapling only the pkg leaves the installed bundles ticketless                | Deliberate, with a stated reason. C3 loads them from their installed location, which is where it would show      |
| The release path runs locally and never in CI, so it can rot unnoticed       | Accepted, and the price of keeping distribution keys out of a public repository. A2 guards the part CI can reach |

## Out of scope

- **Cutting v0.1.0.** No version bump, no tag, no published release. The build plan puts v0.1.0 after Phases 3 through 6, and the trigger modes and measurement UI it names do not exist yet.
- **Notarization in CI.** Decided against above, not deferred.
- **A dmg, per-format zips, or an update feed.** ADR 0013 records why the pkg won; alternatives get a new ADR rather than a revision.
