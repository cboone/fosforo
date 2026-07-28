# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- CLAP plugin factory, descriptor, and instance lifecycle, so the plugin is instantiable by a host for the first time ([#2](https://github.com/cboone/fosforo/issues/2)).
- The permanent CLAP plugin `id`, `com.catamount.fosforo`. Hosts persist this into project files, so it will not change again ([#2](https://github.com/cboone/fosforo/issues/2)).

### Changed

- CI now runs `clap-validator` against the built `.clap` on every push, so the validation ADR 0003 and `AGENTS.md` both call for is enforced rather than left to whoever remembers to run it locally. The validator is pinned to a commit and built with a pinned Rust toolchain, then cached, so upstream cannot turn CI red without a change here ([#10](https://github.com/cboone/fosforo/issues/10)).

### Fixed

- The AUv2 component no longer declares the `resourceUsage` sandbox claims clap-wrapper generates by default, `network.client` and `temporary-exception.files.all.read-write`. The plugin needs neither, and Apple documents the dictionary as mutually exclusive with the `sandboxSafe` flag that was being set alongside it ([#1](https://github.com/cboone/fosforo/issues/1)).
