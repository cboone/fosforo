# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The AUv2 component no longer declares the `resourceUsage` sandbox claims clap-wrapper generates by default, `network.client` and `temporary-exception.files.all.read-write`. The plugin needs neither, and Apple documents the dictionary as mutually exclusive with the `sandboxSafe` flag that was being set alongside it ([#1](https://github.com/cboone/fosforo/issues/1)).
