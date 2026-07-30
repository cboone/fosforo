# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- CLAP plugin factory, descriptor, and instance lifecycle, so the plugin is instantiable by a host for the first time ([#2](https://github.com/cboone/fosforo/issues/2)).
- The permanent CLAP plugin `id`, `com.catamount.fosforo`. Hosts persist this into project files, so it will not change again ([#2](https://github.com/cboone/fosforo/issues/2)).

### Changed

- CI now runs `clap-validator` against the built `.clap` on every push, so the validation that ADR 0003 and `AGENTS.md` both call for is enforced rather than left to whoever remembers to run it locally. The validator is pinned to a commit and built with a pinned Rust toolchain, then cached, so upstream cannot turn CI red without a change here ([#10](https://github.com/cboone/fosforo/issues/10)).
- CI now covers the clap-wrapper-built `.clap` too, not just the Zig-built one. The two share an implementation but not an entry point, so a defect in the clap-wrapper seam used to pass CI silently, and ADR 0003 makes that seam load-bearing. The job that asserted the AU sandbox claims now builds both wrapper artifacts and validates the CLAP, and is renamed from `audio-unit-sandbox` to `clap-wrapper` to match ([#12](https://github.com/cboone/fosforo/issues/12), [#7](https://github.com/cboone/fosforo/issues/7)).
- CI now asserts that every bundle it builds carries a valid signature. For the Audio Unit that assertion is inseparable from the two `Info.plist` checks beside it, because signing seals the plist those checks cover: a signing step that ran too early passes both of them and fails the signature check, and a signing step that was dropped fails only the signature check, so the three together are what pins the order down ([#20](https://github.com/cboone/fosforo/issues/20)).

- CI job timeouts are now set from measured runtimes rather than copied from neighbouring jobs, cutting the worst-case spend on a single wedged macOS job from 45 minutes to 10. Every ceiling sits at roughly 4x the slowest run observed for that job, with the figure and its sample size recorded beside it. The passing path is unaffected; what changes is how long a hung job bills before Actions cancels it, which matters because all but one job runs on `macos-latest` at ten times the Linux rate. `shaders` is a deliberate exception: its ceiling does not budget for the Metal toolchain download, which has never fired on any sampled run and is unmeasured ([#17](https://github.com/cboone/fosforo/issues/17)).

- Supplying a code-signing identity now produces a signature that can actually be notarized. Both signing call sites add `--timestamp` and `--options runtime` whenever the identity is not `-`, because notarization rejects a submission missing either, and an identity on its own was never enough to distribute anything. The two flags follow from the identity rather than being switches of their own, so a distributable signature cannot be half-configured. The default path is untouched and still needs no keychain, no certificate and no network: `--timestamp` would make a plain build reach Apple's timestamp server, and an ad-hoc signature has no certificate whose expiry a timestamp could outlive ([#24](https://github.com/cboone/fosforo/issues/24)).

### Fixed

- The AUv2 component no longer declares the `resourceUsage` sandbox claims clap-wrapper generates by default, `network.client` and `temporary-exception.files.all.read-write`. The plugin needs neither, and Apple documents the dictionary as mutually exclusive with the `sandboxSafe` flag that was being set alongside it ([#1](https://github.com/cboone/fosforo/issues/1)).
- Every bundle the build produces now carries a bundle signature and passes `codesign --verify`. The linker ad-hoc signs the Mach-O binary on arm64, which is why the plugins loaded, but nothing wrote a `Contents/_CodeSignature`, so all three bundles reported `code has no resources but signature indicates they must be present` and none of them was distributable. clap-wrapper cannot supply this: its only signing calls cover its own generated build helper, and it documents bundle signing as the consuming project's decision. Signing is ad-hoc by default, so a plain build still needs no keychain and no certificate, and the identity is a single override away for an eventual release ([#20](https://github.com/cboone/fosforo/issues/20)).
- The plugin presents the same display name in every format. Logic read `Catamount: Fosforo` and described the plugin as `Fosforo CLAP to AU Wrapper`, a string clap-wrapper writes about itself, while REAPER read `Fósforo`. `make_clapfirst_plugins` offers a single `OUTPUT_NAME` that names the bundle file and supplies the display string at once, so the two concerns are now separated by a `POST_BUILD` pass over the generated plist, and the Audio Unit reads `Catamount: Fósforo` with the CLAP descriptor's own description. Bundle filenames, binaries, and `CFBundleExecutable` stay ASCII `Fosforo` ([#9](https://github.com/cboone/fosforo/issues/9)).
