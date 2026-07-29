# 2026-07-29: Make the display name consistent across CLAP and AU

Addresses [#9](https://github.com/cboone/fosforo/issues/9).

## Context

The plugin presents itself under two different names depending on the format, and the Audio Unit additionally exposes a clap-wrapper implementation detail in a user-visible field.

<!-- prettier-ignore -->
| Field                            | Today                        | Wanted                                  |
| -------------------------------- | ---------------------------- | --------------------------------------- |
| CLAP descriptor `name`           | `Fósforo`                    | unchanged                               |
| CLAP bundle `CFBundleName` (Zig) | `Fósforo`                    | unchanged                               |
| AU `AudioComponents.name`        | `Catamount: Fosforo`         | `Catamount: Fósforo`                    |
| AU `AudioComponents.description` | `Fosforo CLAP to AU Wrapper` | `A GPU-rendered phosphor oscilloscope.` |
| AU bundle `CFBundleName`         | `Fosforo`                    | `Fósforo`                               |
| CMake CLAP `CFBundleName`        | `Fosforo`                    | `Fósforo`                               |

So REAPER shows **Fósforo**, Logic shows **Fosforo**, and Logic also shows a description written for the wrapper rather than for this plugin. `AGENTS.md` states the intent plainly: the display name is **Fósforo**, and only the repository, binary, and identifiers stay ASCII `fosforo`. None of these fields is permanent and nothing breaks today, which is why this is polish. But the display name is the entire user-facing identity of a tool whose pitch is care about presentation.

The intended outcome: one display name everywhere a human reads it, one description written for this plugin, and file paths and identifiers still pure ASCII.

## What the investigation settled

**Sub-task 1 is answered: no.** `make_clapfirst_plugins` (`cmake/make_clapfirst.cmake` in the pinned clap-wrapper) takes a single `OUTPUT_NAME` and threads it to every format. There is no display name distinct from it, so setting `PRODUCT_NAME` to `Fósforo` would also rename `Fosforo.component` and `Fosforo.clap` on disk. That is exactly what the ASCII rule exists to prevent.

The AU plist is not `cmake/auv2_Info.plist.in`. Because `AUV2_MANUFACTURER_CODE` is defined, `wrap_auv2.cmake` takes its `--explicit` branch, where a generated `fosforo_auv2-build-helper` executable writes the plist as raw text at build time (`src/detail/auv2/build-helper/build-helper.cpp:56-80`):

- `name` is composed as `manunm + ": " + name`, hence `Catamount: Fosforo`
- `description` is hardcoded as `u.name + " CLAP to AU Wrapper"` (line 247)

clap-wrapper copies that file into the bundle in a `PRE_BUILD` step, so any `POST_BUILD` command on the `_auv2` target sees the copy that ships. That is the same seam `cmake/narrow-au-resource-usage` already uses.

**A rejected alternative.** clap-wrapper's `--fromclap` mode reads `name` and `description` straight from the CLAP descriptor, which would need no post-processing. But `make_clapfirst_plugins` only selects it when `AUV2_MANUFACTURER_CODE` is *un*defined, which then requires the plugin to export clap-wrapper's `clap_plugin_factory_as_auv2` extension and to supply the AU triple from Zig. That moves permanent identifiers (`aufx`/`Fsfr`/`Ctmn`) out of `cmake/CMakeLists.txt` and makes the AU build load the built CLAP. Far too much blast radius for a metadata fix.

**On the accent (sub-task 5).** Every one of the 17 Audio Units installed on this machine is pure ASCII in its `AudioComponents.name`, read directly from their plists, so there is no local precedent to copy. The mechanism should be fine: the plist is UTF-8 and CoreAudio hands hosts a `CFString`. That is a prediction, not a result, which is what the verification below is for.

The survey did confirm the `"Vendor: Product"` shape is universal (`Sixth Sample: Deelay`, `MeldaProduction: MAnalyzer`, `Valhalla DSP, LLC: ValhallaSupermassive`), so that structure stays. It also confirmed `description` is conventionally a short human phrase (Voxengo SPAN uses `FFT spectrum analyzer.`), which is what the CLAP descriptor already carries.

## Changes

### 1. `cmake/set-au-display-name` (new)

A sibling to `cmake/narrow-au-resource-usage`, not an extension of it. The two have different lifecycles: the sandbox script is a workaround that should quietly no-op once clap-wrapper is fixed upstream, while this one is permanent project metadata. Merging them would make both names lie.

Model it closely on the existing script, which is the house style for this: same `--check` flag, same `64`/`65`/`66` exit codes, same `warn()` helper, same `plutil -extract`/`-replace` approach, same doc-comment shape explaining *why* the post-process exists.

Constants at the top, so `--check` needs only a plist path and CI stays a one-liner:

```bash
readonly VENDOR_NAME="Catamount"                          # keep in step with AUV2_MANUFACTURER_NAME
readonly DISPLAY_NAME="Fósforo"                           # keep in step with src/clap/plugin.zig
readonly DESCRIPTION="A GPU-rendered phosphor oscilloscope."  # keep in step with src/clap/plugin.zig
```

Behavior:

- Reuse the existing `audio_component_count` shape to fail loudly on a plist with no usable `AudioComponents` array, rather than reporting a vacuous pass.
- Before rewriting, assert the current `AudioComponents.<i>.name` begins with `"${VENDOR_NAME}: "`. If `AUV2_MANUFACTURER_NAME` ever changes in `cmake/CMakeLists.txt` without this script following, that turns a silent inconsistency into a build failure. Skip this guard in `--check` mode, where the prefix is by definition already correct.
- Set, for every entry: `AudioComponents.<i>.name` to `"${VENDOR_NAME}: ${DISPLAY_NAME}"` and `AudioComponents.<i>.description` to `${DESCRIPTION}`.
- Set the top-level `CFBundleName` to `${DISPLAY_NAME}`. Leave `CFBundleExecutable` alone: it names the actual binary and stays ASCII `Fosforo`.
- `--check` asserts all three without modifying anything, so CI can catch the `POST_BUILD` step having been dropped altogether. A rewriting step cannot detect its own absence; that is the reasoning `narrow-au-resource-usage` already records and it applies unchanged here.

Invoke the `write-bash-scripts` skill before writing it.

### 2. `cmake/CMakeLists.txt`

- Add `set(DISPLAY_NAME "Fósforo")` next to the existing `set(PRODUCT_NAME "Fosforo")`, with a comment drawing the line: `PRODUCT_NAME` names files and the binary and stays ASCII; `DISPLAY_NAME` is what a human reads.
- After `make_clapfirst_plugins()` returns, override the CMake-built CLAP's bundle name:

  ```cmake
  set_target_properties(${PROJECT_NAME}_clap PROPERTIES MACOSX_BUNDLE_BUNDLE_NAME "${DISPLAY_NAME}")
  ```

  `target_add_clap_configuration` sets this to `OUTPUT_NAME`, and CMake's default bundle template writes it out as `CFBundleName`. `LIBRARY_OUTPUT_NAME` is untouched, so the file stays `Fosforo.clap`. This is Finder-only polish: CLAP hosts read the descriptor, not the plist.
- Register the new script as a second `POST_BUILD` command on `${PROJECT_NAME}_auv2`, immediately after the `narrow-au-resource-usage` block and inside the same `if(APPLE AND TARGET ...)` guard. The two touch disjoint keys, so their order does not matter. Carry a comment in the established voice explaining why a post-process is needed at all (the `OUTPUT_NAME` double duty above).

### 3. `.github/workflows/ci.yml`

- Rename `audio-unit-sandbox` to `audio-unit-metadata`. It now asserts two independent properties of the generated plist and the old name only covers one. `main` has no branch protection, so no required status check breaks.
- Rewrite the job's leading comment to cover both concerns without losing the existing sandbox rationale.
- Add a step after the existing assertion:

  ```yaml
  - name: Assert the component carries the display name
    run: |
      ./cmake/set-au-display-name --check \
        build/assets/Fosforo.component/Contents/Info.plist
  ```

The job already builds `fosforo_auv2` from scratch and the `POST_BUILD` is attached to that target, so no build change is needed.

### 4. `AGENTS.md`

Add a Gotchas bullet naming every place the display string lives, since it now spans three toolchains and cannot be derived from one source:

- `src/clap/plugin.zig` (CLAP descriptor `name` and `description`, the source of truth)
- `macos/Info.plist` (`CFBundleName`, `CFBundleDisplayName`, for the Zig-built bundle)
- `cmake/CMakeLists.txt` (`DISPLAY_NAME`, for the CMake-built CLAP)
- `cmake/set-au-display-name` (for the AU, rewritten after clap-wrapper generates the plist)

`CLAUDE.md` is a symlink to `AGENTS.md`, so it follows automatically.

## Not changing

- `PRODUCT_NAME`, `OUTPUT_NAME`, `CFBundleExecutable`, and every bundle filename stay ASCII `Fosforo`.
- The AU triple (`aufx`/`Fsfr`/`Ctmn`), the CLAP `id` (`com.catamount.fosforo`), and `CFBundleIdentifier` (`com.cboone.fosforo`). All permanent or sticky per the identifiers section of `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`.
- `src/clap/plugin.zig`. It is already correct and its `descriptor.name` test at line 667 already guards it.

## Verification

This is the empirical gate on sub-task 5. Run it **before** committing; if any step mangles the accent, stop and fall back to ASCII everywhere (change `src/clap/plugin.zig`, `macos/Info.plist`, and `AGENTS.md` to `Fosforo` instead) and record why in the issue.

Build and read the plist back:

```bash
cmake -B build cmake/
cmake --build build --target fosforo_all
PLIST=build/assets/Fosforo.component/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :AudioComponents:0:name" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :AudioComponents:0:description" "$PLIST"
plutil -extract CFBundleName raw -o - -- "$PLIST"
plutil -extract CFBundleExecutable raw -o - -- "$PLIST"
```

Expect `Catamount: Fósforo`, `A GPU-rendered phosphor oscilloscope.`, `Fósforo`, and `Fosforo`. Confirm the bundle on disk is still `Fosforo.component` and the CMake-built CLAP is still `Fosforo.clap`.

Confirm both assertions hold and that neither script broke the other:

```bash
./cmake/set-au-display-name --check "$PLIST"
./cmake/narrow-au-resource-usage --check "$PLIST"
```

Confirm the rewrite is idempotent by building twice without cleaning, then re-running `--check`.

Check what CoreAudio makes of it, which is the part that cannot be predicted:

```bash
cp -R build/assets/Fosforo.component ~/Library/Audio/Plug-Ins/Components/
killall AudioComponentRegistrar
auval -a | grep -i -e fosforo -e sforo
auval -v aufx Fsfr Ctmn
```

`auval -a` must render the accent rather than a replacement character or mojibake, and `auval -v` must still resolve the component by its triple.

Then in the hosts, since caches hide changes:

```bash
rm -rf ~/Library/Caches/AudioUnitCache
```

- **Logic**: relaunch and confirm the plugin browser shows **Fósforo** grouped under **Catamount**, with the new description. The `"Vendor: Product"` split must still work; a broken split shows up as the plugin landing in the wrong vendor group or as the full string appearing as one name.
- **REAPER**: confirm the CLAP still shows **Fósforo**, unchanged.

Finally, the ordinary gates:

```bash
zig build test
zig fmt --check build.zig src/
```

`clap-validator` and the Zig tests should be untouched by this change; run them to confirm that.

### Results

Everything passed, including the host check.

At the build level, `cmake --build build --target fosforo_all` produced `Catamount: Fósforo`, `A GPU-rendered phosphor oscilloscope.`, `CFBundleName = Fósforo`, and `CFBundleExecutable = Fosforo`, with the AU triple still `aufx`/`Fsfr`/`Ctmn` and both bundles still named `Fosforo.component` and `Fosforo.clap` on disk. Both `--check` assertions pass, and still pass after a rebuild without cleaning, so the rewrite is idempotent and the two scripts do not interfere. `zig build test`, `zig fmt --check`, `shellcheck`, `actionlint`, and `markdownlint-cli2` are all clean.

**Sub-task 5 is answered: yes, the AU can carry the accent.** Logic's plugin browser shows **Fósforo** under **Catamount** with the new description, rendered correctly, with the `"Vendor: Product"` split intact. Confirmed against an ASCII control bundle installed alongside it under a throwaway subtype, which ruled out the accent as a cause when neither bundle appeared during earlier attempts.

Two notes for whoever verifies an Audio Unit next, both of which cost a long detour here:

- **`auval -a` and `AudioComponentFindNext` both enumerate only Apple's built-in components on this macOS,** even from an ordinary terminal, while Logic sees every installed AU. A null result from either tool means nothing. Use a host.
- **`~/Library/Caches/AudioUnitCache` is not the registration cache on this macOS** and deleting it changes nothing. AU capability data lives in `~/Library/Preferences/com.apple.audio.AudioComponentCache.plist`. Relaunching Logic is what triggers a rescan; `killall AudioComponentRegistrar` does not help, and `launchctl kickstart` is refused under SIP.

### Found along the way, out of scope here

The AUv2 bundle is never code-signed by the build. The linker ad-hoc signs the arm64 binary, but there is no `_CodeSignature` directory, so `codesign --verify` fails with "code has no resources but signature indicates they must be present" where a working AU reports `valid on disk`. The component above was signed by hand to test it, which is not reproducible from a clean build. Filed separately. That issue carries a constraint this plan creates: once the bundle is signed, `Info.plist` becomes sealed, so signing has to run *after* both `POST_BUILD` scripts, not before.
