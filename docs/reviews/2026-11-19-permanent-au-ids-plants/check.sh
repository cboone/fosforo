#!/usr/bin/env bash
# Run the Audio Unit identifier assertion from the wrapper CI job.

set -euo pipefail

function main() {
  local step
  step="$(yq -er '
    .jobs."clap-wrapper".steps[]
    | select(.name == "Assert the component carries the permanent Audio Unit identifiers")
    | .run
  ' .github/workflows/ci.yml)"
  [[ -n "${step}" ]]
  printf 'Checking built Audio Unit identifiers\n'
  bash --noprofile --norc -eo pipefail -c "${step}"
  printf 'PASS built Audio Unit identifiers\n'
}

main "$@"
