# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- CLAP plugin factory, descriptor, and instance lifecycle, so the plugin is instantiable by a host for the first time ([#2](https://github.com/cboone/fosforo/issues/2)).
- The permanent CLAP plugin `id`, `com.catamount.fosforo`. Hosts persist this into project files, so it will not change again ([#2](https://github.com/cboone/fosforo/issues/2)).
- A GUI smoke harness, `zig build smoke`, which is the only thing in the project that runs a Metal or an AppKit call rather than type-checking one. It plays the host: a real `NSWindow`, the real `clap_entry`, and the editor opened and torn down repeatedly through the `clap.gui` vtable. Split into a `gpu` half that needs no window and covers runtime shader compilation, which `zig build validate-shaders` cannot prove, and an `appkit` half that covers view embedding and the lifecycle. `zig build smoke-leaks` wraps the second in `leaks --atExit` and fails if anything this project owns survives 400 open and close cycles. Never part of `zig build test`, so the default build stays hermetic ([#19](https://github.com/cboone/fosforo/issues/19), [ADR 0013](docs/adr/0013-gui-smoke-harness-as-a-build-step.md)).
- CI runs the smoke harness on every push. The `gpu` half is required; the `appkit` half runs under `continue-on-error` until a real run settles whether a hosted runner grants an unbundled process a window-server connection ([#19](https://github.com/cboone/fosforo/issues/19)).

### Changed

- CI now runs `clap-validator` against the built `.clap` on every push, so the validation that ADR 0003 and `AGENTS.md` both call for is enforced rather than left to whoever remembers to run it locally. The validator is pinned to a commit and built with a pinned Rust toolchain, then cached, so upstream cannot turn CI red without a change here ([#10](https://github.com/cboone/fosforo/issues/10)).
- CI now covers the clap-wrapper-built `.clap` too, not just the Zig-built one. The two share an implementation but not an entry point, so a defect in the clap-wrapper seam used to pass CI silently, and ADR 0003 makes that seam load-bearing. The job that asserted the AU sandbox claims now builds both wrapper artifacts and validates the CLAP, and is renamed from `audio-unit-sandbox` to `clap-wrapper` to match ([#12](https://github.com/cboone/fosforo/issues/12), [#7](https://github.com/cboone/fosforo/issues/7)).

### Fixed

- The AUv2 component no longer declares the `resourceUsage` sandbox claims clap-wrapper generates by default, `network.client` and `temporary-exception.files.all.read-write`. The plugin needs neither, and Apple documents the dictionary as mutually exclusive with the `sandboxSafe` flag that was being set alongside it ([#1](https://github.com/cboone/fosforo/issues/1)).
- The plugin presents the same display name in every format. Logic read `Catamount: Fosforo` and described the plugin as `Fosforo CLAP to AU Wrapper`, a string clap-wrapper writes about itself, while REAPER read `Fósforo`. `make_clapfirst_plugins` offers a single `OUTPUT_NAME` that names the bundle file and supplies the display string at once, so the two concerns are now separated by a `POST_BUILD` pass over the generated plist, and the Audio Unit reads `Catamount: Fósforo` with the CLAP descriptor's own description. Bundle filenames, binaries, and `CFBundleExecutable` stay ASCII `Fosforo` ([#9](https://github.com/cboone/fosforo/issues/9)).
