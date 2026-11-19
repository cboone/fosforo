#!/usr/bin/env bash
# Run assertions against the fixture prepared for this source variant.
set -euo pipefail

function main() {
  export MEASURE_PARITY_BINARY
  MEASURE_PARITY_BINARY="$(cat .measurement-binary)"
  uv run --offline --with pillow --with numpy python scripts/test-measure-trace.py -v
}

main "$@"
