#!/usr/bin/env bash
set -euo pipefail

function check_report() {
  local name="${1}"
  local expected_status="${2}"
  local expected_message="${3}"
  local report="${4}"
  local output
  local status=0

  output="$(LEAK_REPORT="${report}" ./scripts/smoke-leak-check --cycles 40 /usr/bin/true 2>&1)" || status=${?}
  if [[ ${status} -ne ${expected_status} ]] || ! grep -Fxq "smoke-leak-check: ${expected_message}" <<< "${output}"; then
    printf 'FAIL: %s: expected exit %s, got %s\n%s\n' "${name}" "${expected_status}" "${status}" "${output}" >&2
    return 1
  fi
  printf 'PASS: %s (exit %s)\n' "${name}" "${status}"
}

function main() {
  local selected="${1:-}"
  local fixture
  local name expected_status expected_message report
  local matched=0
  fixture="$(mktemp -d -t smoke-leak-fixture)"
  # shellcheck disable=SC2064 # Expand while the path is in scope.
  trap "rm '${fixture}/leaks' && rmdir '${fixture}'" EXIT

  cat > "${fixture}/leaks" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'smoke: appkit ok'
if [[ "${LEAK_REPORT}" != *'leaks Report Version:'* ]]; then
  printf '%s\n' 'leaks Report Version: 4.0'
fi
printf '%s\n' "${LEAK_REPORT}"
[[ ${LEAK_REPORT} =~ ^(Process\ [0-9]+:\ )?0\ leaks\ for\  ]]
EOF
  chmod +x "${fixture}/leaks"
  export PATH="${fixture}:${PATH}"

  while IFS='|' read -r name expected_status expected_message report; do
    if [[ -z "${selected}" || "${selected}" == "${name}" ]]; then
      check_report "${name}" "${expected_status}" "${expected_message}" "$(printf '%b' "${report}")" || return 1
      matched=1
    fi
  done << 'EOF'
zero|0|report parsed, 0 distinct leaked classes|Process 31405: 0 leaks for 0 total leaked bytes.
singular|0|nothing this project owns was leaked, and 16 bytes is inside the 1048576-byte bound|Process 5364: 1 leak for 16 total leaked bytes.
plural|0|nothing this project owns was leaked, and 18816 bytes is inside the 1048576-byte bound|Process 123: 288 leaks for 18816 total leaked bytes.
byte|0|nothing this project owns was leaked, and 1 bytes is inside the 1048576-byte bound|2 leaks for 1 total leaked byte
exact-over-bound|65|41943040 bytes leaked, above the 1048576-byte bound|40 leaks for 41943040 total leaked bytes
scaled-zero|0|nothing this project owns was leaked, and 0 bytes is inside the 1048576-byte bound|0 leaks for 0B total leaked.
kilo|0|nothing this project owns was leaked, and 1127 bytes is inside the 1048576-byte bound|2 leaks for 1.1K total leaked bytes.
mega|0|nothing this project owns was leaked, and 1048576 bytes is inside the 1048576-byte bound|2 leaks for 1 MB total leaked.
fractional-mega|65|1153434 bytes leaked, above the 1048576-byte bound|2 leaks for 1.1 MiB total leaked.
giga|65|1073741824 bytes leaked, above the 1048576-byte bound|2 leaks for 1G total leaked bytes.
tera|65|1099511627776 bytes leaked, above the 1048576-byte bound|2 leaks for 1T total leaked bytes.
peta|65|1125899906842624 bytes leaked, above the 1048576-byte bound|2 leaks for 1P total leaked bytes.
exa|65|9223372036854775808 bytes leaked, above the 1048576-byte bound|2 leaks for 8E total leaked bytes.
editor-class|65|these leaked objects belong to this project:|Process 123: 1 leak for 16 total leaked bytes.\nROOT LEAK: <NSView 0x123>
bad-unit|69|leaks produced no parseable report (exit 1); the checks below would be vacuous|2 leaks for 1Q total leaked bytes.
duplicate|69|leaks produced no parseable report (exit 1); the checks below would be vacuous|2 leaks for 16 total leaked bytes.\n2 leaks for 32 total leaked bytes.
before-marker|69|leaks produced no parseable report (exit 1); the checks below would be vacuous|2 leaks for 16 total leaked bytes.\nleaks Report Version: 4.0
EOF
  if [[ ${matched} -eq 0 ]]; then
    printf 'FAIL: unknown report fixture %s\n' "${selected}" >&2
    return 1
  fi
}

main "$@"
