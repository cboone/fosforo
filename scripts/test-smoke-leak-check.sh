#!/usr/bin/env bash
set -euo pipefail

function check_report() {
  local report="${1}"
  local expected_status="${2}"
  local expected_message="${3}"
  local output
  local status=0

  output="$(LEAK_REPORT="${report}" ./scripts/smoke-leak-check --cycles 40 /usr/bin/true 2>&1)" || status=${?}
  if [[ ${status} -ne ${expected_status} ]] || ! grep -Fxq "smoke-leak-check: ${expected_message}" <<< "${output}"; then
    printf 'FAIL: %s: expected exit %s, got %s\n%s\n' "${report}" "${expected_status}" "${status}" "${output}" >&2
    return 1
  fi
  printf 'PASS: %s (exit %s)\n' "${report}" "${status}"
}

function main() {
  local fixture
  fixture="$(mktemp -d -t smoke-leak-fixture)"
  # shellcheck disable=SC2064 # Expand while the path is in scope.
  trap "rm '${fixture}/leaks' && rmdir '${fixture}'" EXIT

  cat > "${fixture}/leaks" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'smoke: appkit ok' 'leaks Report Version: 4.0' "${LEAK_REPORT}"
[[ ${LEAK_REPORT} == '0 leaks for 0 total leaked bytes' ]]
EOF
  chmod +x "${fixture}/leaks"
  export PATH="${fixture}:${PATH}"

  check_report '0 leaks for 0 total leaked bytes' 0 'report parsed, 0 distinct leaked classes'
  check_report '40 leaks for 41943040 total leaked bytes' 65 '41943040 bytes leaked, above the 1048576-byte bound'
}

main "$@"
