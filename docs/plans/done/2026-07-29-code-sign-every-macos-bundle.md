# Code sign every macOS bundle the build produces

Addresses [#20](https://github.com/cboone/fosforo/issues/20).

## Context

Every bundle this repository produces fails `codesign --verify`. The linker ad-hoc signs the Mach-O binary, which is automatic and mandatory on arm64 and is why the plugins load at all, but nothing signs the *bundle*. Without `Contents/_CodeSignature/CodeResources`, `codesign` reports:

```console
code has no resources but signature indicates they must be present
```

Confirmed against the installed artifacts. The Zig-built `.clap` produces that exact error and reports `Sealed Resources=none`, `flags=0x20002(adhoc,linker-signed)`. Issue #20 records the same for the `.component`. clap-wrapper cannot help: at the pinned commit `35f524b`, its only `codesign` calls are in `cmake/wrap_auv2.cmake`, and all three sign the *generated build helper executable*, never a plugin bundle. `cmake/wrap_clap.cmake` contains no `codesign` at all, and `cmake/make_clapfirst.cmake:270` says signing is the consuming project's job.

Three things are wrong as a result:

- An unsigned bundle is not distributable. A Developer ID signature and notarization both start here.
- `cmake/CMakeLists.txt:155` reasons *from* the absence of a signature to justify its `POST_BUILD` plist rewrites: "Nothing signs the .component on this path, so there is no signature to invalidate." True today, false the moment signing lands.
- Verifying a component locally means remembering to sign it by hand, which is exactly the step that gets skipped and then blamed on something else.

The intended outcome: `zig build` and `cmake --build` each emit bundles that pass `codesign --verify` with no keychain access and no certificate, a release identity is one cache variable away, and CI proves it on every push.

### The ordering constraint

**Signing must be the last thing that touches the AUv2 bundle.** `cmake/narrow-au-resource-usage` and `cmake/set-au-display-name` both rewrite `Contents/Info.plist` as `POST_BUILD` commands. Signing seals that plist into `CodeResources`. Signing first yields a component whose signature no longer matches its own plist, and `codesign --verify` then reports tampering rather than a missing signature: strictly worse than not signing.

`POST_BUILD` commands run in registration order, so "registered last" is the mechanism. clap-wrapper's own bundle-touching commands are registered inside `make_clapfirst_plugins()` (the `PRE_BUILD` plist copy in `wrap_auv2.cmake:279`, and `macos_bundle_flag`'s `PkgInfo` copy in `shared_prologue.cmake:267`), so anything registered after that call already runs after both.

## Decisions

- **All three bundles get signed**, not just the component. One assertable rule ("every bundle this repo produces verifies") beats a rule that has to be explained.
- **`/usr/bin/codesign` does not compromise ADR 0009.** It is a base-OS binary (`root:wheel`, universal, and `xcrun --find codesign` returns `/usr/bin/codesign` itself), not an on-demand Xcode component like the Metal toolchain. Verified.
- **Ad-hoc (`-`) is the default identity**, behind a cache variable and a `zig build` option. `security find-identity -v -p codesigning` finds one Apple Development certificate and no Developer ID Application certificate, so release signing is not possible on this machine today regardless.
- **Release signing flags are out of scope.** `--timestamp`, `--options runtime`, and entitlements are useless without notarization, which gets its own issue.
- **No new shell script.** The existing two exist because they need `plutil` surgery and a `--check` mode; a signature is verified with `codesign --verify`, so CMake and the CI workflow are the only surfaces. This also avoids the `.editorconfig` section-list gotcha.

## Work

### 1. Mark the issue in progress

```bash
gh issue edit 20 --add-assignee @me
gh label create "in progress" --description "Work is actively being done" --color FBCA04 2>/dev/null || true
gh issue edit 20 --add-label "in progress"
```

### 2. Sign the CMake bundles: `cmake/CMakeLists.txt`

Append a new section at the **end of the file**, after the plist-correction block. Placement is the ordering mechanism, not a stylistic choice.

- A cache variable, `FOSFORO_CODESIGN_IDENTITY`, defaulting to `"-"`. Naming follows the existing `FOSFORO_FORMATS`.
- A `fosforo_sign_bundle(target)` function wrapping one `add_custom_command(TARGET ${target} POST_BUILD ... VERBATIM)` that runs `codesign --force --sign "${FOSFORO_CODESIGN_IDENTITY}" "$<TARGET_BUNDLE_DIR:${target}>"`.
  - Use `$<TARGET_BUNDLE_DIR:...>` rather than `$<TARGET_FILE_DIR:...>/../..`; it says what it means. **Do not** use the sibling `$<TARGET_BUNDLE_DIR_NAME:...>` in the `COMMENT`: it needs CMake 3.24 and this file declares 3.21. Keep the `COMMENT` literal text.
- Call it for `${PROJECT_NAME}_auv2` (guarded by `APPLE AND TARGET`, matching the block above) and for `${PROJECT_NAME}_clap` (guarded by `TARGET`, matching the block at line 137).

Comment the ordering constraint at the call site, not only in the section header, because the failure mode is someone appending a fourth `POST_BUILD` command below it.

### 3. Sign the Zig bundle: `build.zig`

Inside `installClapBundle`, which already owns bundle assembly and the `install-clap` step:

```zig
const identity = b.option([]const u8, "codesign-identity", "...") orelse "-";
const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", identity });
sign.addDirectoryArg(.{ .cwd_relative = b.getInstallPath(.{ .custom = "Fosforo.clap" }, "") });
sign.step.dependOn(&binary.step);
sign.step.dependOn(&plist.step);
b.getInstallStep().dependOn(&sign.step);
```

Depending on `binary` and `plist` individually, rather than on `b.getInstallStep()`, is what avoids a cycle: the install step is what depends on signing. The `cwd_relative` + `addDirectoryArg` pattern is already proven by the `install-clap` copy step directly below.

Two consequences to note in comments:

- The step re-runs on every `zig build`. A `Run` step with no output arguments reports side effects and is never cached. Re-signing is idempotent and costs milliseconds on a bundle this size.
- `zig build install-clap` depends on the install step, so the copy landing in `~/Library/Audio/Plug-Ins/CLAP` now carries the signature. `cp -R` preserves `_CodeSignature`.

### 4. Assert it in CI: `.github/workflows/ci.yml`

Note that issue #20 names the job `audio-unit-metadata`; it is actually `clap-wrapper`, renamed in #12.

- **`clap-validator` job**, after `Build the plugin`: `codesign --verify --strict --verbose zig-out/Fosforo.clap`.
- **`clap-wrapper` job**, after both `--check` plist assertions: the same command against `build/assets/Fosforo.component` and `build/assets/Fosforo.clap`.

Placement after the plist assertions is deliberate and belongs in a comment: **the three steps together are the ordering test.** Signing before the rewrites passes both `--check` steps and fails the signature check; a dropped signing step fails only the signature check. Either failure is distinguishable, and neither is detectable by a rewriting step inspecting its own work.

`--verify --verbose` reports both `valid on disk` and `satisfies its Designated Requirement`. Skip `--deep`: no bundle here contains nested code (`AUV2_MACOSX_EMBEDDED_CLAP_LOCATION` is unset, so `macos_include_clap_in_bundle` embeds nothing), and `--strict` covers what matters.

### 5. Correct the documentation that reasons from the absence of a signature

- **`cmake/CMakeLists.txt:155-156`**. Replace "Nothing signs the .component on this path, so there is no signature to invalidate" with the inverse: both rewrites must stay ahead of the signing step at the end of the file, because signing seals the plist they edit.
- **`AGENTS.md`, gotcha at line 81** ("The AUv2 build rewrites its own `Info.plist`"). It now describes three `POST_BUILD` commands, with signing last and load-bearing.
- **`AGENTS.md`, new gotcha.** Every bundle is ad-hoc signed by the build. Distinguish the linker's Mach-O signature (automatic on arm64, `flags=0x20002(adhoc,linker-signed)`, `Sealed Resources=none`) from the bundle signature `codesign --verify` requires. Name both overrides: `-DFOSFORO_CODESIGN_IDENTITY=` and `zig build -Dcodesign-identity=`.
- **`AGENTS.md`, Development section.** Add the `codesign --verify` command to the block, and correct the `auval` sentence at line 71, which currently recommends a tool that returns a false negative here.

### 6. Record the two verification findings from #20

Both as `AGENTS.md` gotchas, since they are exactly the kind of thing that file exists for:

- **`auval -a` and `AudioComponentFindNext` enumerate only Apple's built-in components** on Darwin 25.5.0, from an ordinary terminal outside any sandbox, while Logic sees every installed Audio Unit. A null result from either is not evidence; use a host.
- **`~/Library/Caches/AudioUnitCache` is not the AU registration cache.** Deleting it, the standard advice, changes nothing and it is not rebuilt. Capability data lives in `~/Library/Preferences/com.apple.audio.AudioComponentCache.plist`. Relaunching Logic triggers a rescan; `killall AudioComponentRegistrar` does not, and `launchctl kickstart` is refused under SIP.

### 7. `CHANGELOG.md`

Under `[Unreleased]`: a **Fixed** entry for the bundles now carrying signatures, and a **Changed** entry for CI asserting them, both linking #20. Match the existing entries' register: they state what was wrong and why it mattered, not just what changed.

### 8. Follow-up issue for notarization

Filed as [#24](https://github.com/cboone/fosforo/issues/24), referenced from the `FOSFORO_CODESIGN_IDENTITY` comment so the deferred release-signing flags have a destination. Scope: Developer ID Application certificate, `--timestamp`, `--options runtime`, an entitlements file, `notarytool submit --wait`, `xcrun stapler`, and where the credentials live. Blocked on a release process that does not exist yet, and on a certificate this machine does not have.

Use the `create-issue` skill; it routes the body through a tmpfile.

## Files

- `cmake/CMakeLists.txt`: new signing section at the end of the file, and the corrected comment at 155-156.
- `build.zig`: a `codesign` step wired into `installClapBundle`, plus a `codesign-identity` option.
- `.github/workflows/ci.yml`: one assertion step in `clap-validator`, one in `clap-wrapper`.
- `AGENTS.md`: one gotcha amended, three added, and the Development section corrected.
- `CHANGELOG.md`: two `[Unreleased]` entries.

`CLAUDE.md` is a symlink to `AGENTS.md`; edit only the latter. No `.editorconfig` change: no new shell script.

Invoke the `write-markdown` skill before editing `AGENTS.md` and `CHANGELOG.md`.

## Verification

The three commands from #20, which must pass **together**. Passing the last two while failing the first is exactly the wrong-order failure.

```bash
cmake -B build cmake/
cmake --build build --target fosforo_all
codesign --verify --strict --verbose build/assets/Fosforo.component
./cmake/narrow-au-resource-usage --check build/assets/Fosforo.component/Contents/Info.plist
./cmake/set-au-display-name --check build/assets/Fosforo.component/Contents/Info.plist
```

Then the rest:

```bash
zig build
codesign --verify --strict --verbose zig-out/Fosforo.clap
codesign --verify --strict --verbose build/assets/Fosforo.clap
codesign -dvv zig-out/Fosforo.clap 2>&1 | grep -E 'Sealed Resources|flags'
clap-validator validate zig-out/Fosforo.clap
clap-validator validate build/assets/Fosforo.clap
zig build test
zig fmt --check build.zig src/
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
```

What each one is for:

- `codesign -dvv` should report a sealed-resources count and `flags=0x2(adhoc)`, **not** `Sealed Resources=none` or `linker-signed`. `--verify` alone already fails on the linker-signed case, so this is confirmation rather than the gate.
- Both `clap-validator` runs confirm bundle signing did not disturb `dlopen`. Ad-hoc signing should be transparent to it; this is the check that proves so rather than assuming.
- `zig build test` and `zig fmt --check` cover the `build.zig` edit. `shfmt` is unaffected but cheap, and CI runs it.
- Optional, and the only step that needs a DAW: install with `zig build install-clap`, copy the component to `~/Library/Audio/Plug-Ins/Components/`, relaunch Logic, and confirm it still loads. Per the gotcha above, `auval` cannot answer this.

The current `~/Library/Audio/Plug-Ins/Components/Fosforo.component` was signed **by hand** during #20's investigation, so it already verifies. Re-verifying it proves nothing about the build. Verify `build/assets/` output only.

## Commits

Split by conventional type, matching this repository's history (`fix`, `ci`, `docs` all in use):

1. `fix: code sign the bundles the build produces (#20)`, covering `cmake/CMakeLists.txt` and `build.zig`.
2. `ci: assert the bundle signatures (#20)`, covering `.github/workflows/ci.yml`.
3. `docs: record how bundle signing works and how to verify an AU (#20)`, covering `AGENTS.md` and `CHANGELOG.md`.

All GPG signed. If step 2 or 3 is reached before step 1 verifies, stop and fix step 1 first: a CI assertion committed ahead of the thing it asserts is a red build on purpose.
