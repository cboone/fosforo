#!/usr/bin/env bash
# Check copied configurations only; FOSFORO_NODE_BIN supplies locked tools.
set -euo pipefail

function main() {
  mkdir -p .workmux
  printf 'Local prompt without a heading.   \n' > .workmux/PROMPT-x.md
  printf '# Control\n' > CONTROL.md
  printf 'Checking workmux exclusions\n'
  if ! "${FOSFORO_NODE_BIN}/markdownlint-cli2"; then
    printf 'FAIL markdownlint exclusion\n'
    exit 1
  fi
  "${FOSFORO_NODE_BIN}/prettier" --file-info .workmux/PROMPT-x.md > file-info.json
  if ! node -e 'if (!require("./file-info.json").ignored) process.exit(1)'; then
    printf 'FAIL Prettier exclusion\n'
    exit 1
  fi
  printf 'PASS workmux exclusions\n'
}

main "$@"
