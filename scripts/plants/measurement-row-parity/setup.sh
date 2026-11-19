#!/usr/bin/env bash
# Compile the real fixture before the assertion phase.
set -euo pipefail

function main() {
  local build_dir
  build_dir="$(mktemp -d "${PWD}/.measurement-build.XXXXXX")"
  uv run --offline --with pillow --with numpy python scripts/test-measure-trace.py \
    --prepare "${build_dir}" > .measurement-binary
}

main "$@"
