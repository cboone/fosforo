# Editor leak gate verification

[Issue 156](https://github.com/cboone/fosforo/issues/156) makes the 40-cycle editor leak step fail the smoke job while keeping the outcome and runner-image summary.

The local `zig build smoke-leaks -Dleak-cycles=40` stopped during configuration. The installed Zig 0.17.1 lacks the `Build.build_root` field used by the project, which pins 0.16.0. The plant therefore exercises the real judge and workflow shell with a fixture at the `leaks` report boundary.

The checked runner executes `bash -euo pipefail check.sh` in a private copy. The check reads the `smoke` job from `ci.yml`, checks that both the job and the leak step omit `continue-on-error`, and executes the extracted `run` block under `/bin/bash -e`. That block runs `zig build smoke-leaks -Dleak-cycles=40 2>&1 | tee leaks.log` with `pipefail`. A fixture shim for `zig` invokes the judge with `./scripts/smoke-leak-check --cycles 40 /usr/bin/true` and forwards its status. A fixture shim for `leaks` prints the report and returns 1 in all runs.

The baseline report contains the AppKit success marker, a parseable summary with 64 leaked bytes, and one `NSXPCConnection` allocation. The leak plant adds an `NSView` and adjusts the summary to 128 bytes. The real judge parsed the report, printed the editor-owned `NSView`, and returned its leak verdict through the pipeline. Restoring the report restored the successful verdict. A second plant restores `continue-on-error: true` on the leak step and checks that the workflow policy assertion catches it.

This verifies the judge's response to the planted input and the shell's propagation of that verdict. It uses a simulated build entry point and does not exercise the native AppKit smoke process or a hosted Actions job.

<!-- checked-plants:start -->

## Verified plants and controls

plant editor-owned-leak: named assertion reached; red exit 65; restored; green exit 0.

plant tolerated-step-failure: named assertion reached; red exit 78; restored; green exit 0.

Evidence: `verification/leak-gate.8p2CJg/run/results.json`.

<!-- checked-plants:end -->

## Zero-leak judge regression

plant zero-leak-report-without-classes: named assertion reached; red exit 1; restored; green exit 0.

Evidence: `verification/zero-leak-plant.8kYNWw/run/results.json`.

## Round 2 report parser audit

The local `leaks(1)` manual defines binary units, including `1K` as 1024 bytes. The [stored smoke report](2026-07-29-gui-smoke-harness-as-a-build-step.md) records the plural summary with exact bytes. A local `leaks --atExit` probe confirmed zero and singular summaries with exact bytes and decimal binary units in the detail lines. The scaled-summary fixtures exercise that unit convention synthetically.

| Report consumer                                                                 | Audit result                                                                                                                           |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Harness success marker in `main`                                                | Unchanged. Requires the AppKit success line before interpreting the report.                                                            |
| Report version marker in `report_body`                                          | Unchanged. Supplies the report body to both the summary parser and class extractor.                                                    |
| Summary presence, byte extraction and summary text in `main` and `leaked_bytes` | Changed. `leak_summary` parses exactly one summary after the marker and returns its original text and normalized bytes.                |
| Class extraction in `leaked_classes` and ownership matching in `main`           | Unchanged. Keeps classless totals and checks the class prefixes when present.                                                          |
| Byte bound in `main`                                                            | Changed. Compares normalized bytes, including scaled totals larger than Bash's signed integer range, against the existing 1 MiB limit. |

The exact-byte zero and plural fixtures are compatibility controls. The round-one receipt above covers the zero-report regression from before the class extractor fix.

### Verified parser plants and controls

plant singular: named assertion reached; red exit 1; restored; green exit 0.

plant byte: named assertion reached; red exit 1; restored; green exit 0.

plant scaled-zero: named assertion reached; red exit 1; restored; green exit 0.

plant kilo: named assertion reached; red exit 1; restored; green exit 0.

plant mega: named assertion reached; red exit 1; restored; green exit 0.

plant fractional-mega: named assertion reached; red exit 1; restored; green exit 0.

plant giga: named assertion reached; red exit 1; restored; green exit 0.

plant tera: named assertion reached; red exit 1; restored; green exit 0.

plant peta: named assertion reached; red exit 1; restored; green exit 0.

plant exa: named assertion reached; red exit 1; restored; green exit 0.

plant editor-class: named assertion reached; red exit 1; restored; green exit 0.

plant before-marker: named assertion reached; red exit 1; restored; green exit 0.

control zero: green control verified; control exit 0; restored; green exit 0.

control plural: green control verified; control exit 0; restored; green exit 0.

control exact-over-bound: green control verified; control exit 0; restored; green exit 0.

Evidence: `verification/leak-summary-plants.rKytzX/run/results.json`.

## Round 3 byte-bound guard plant

In a worktree-local copy, remove only `${#bytes} -gt ${#MAXIMUM_LEAKED_BYTES} ||` from the byte comparison. Run `/bin/bash scripts/test-smoke-leak-check.sh exa` before the change, with the guard removed, and after restoring the judge byte for byte. The parser stays intact in all three runs.

The `8E` fixture went red with test exit 1. The judge parsed `9223372036854775808` bytes and wrongly accepted the total with exit 0. After restoration, the fixture passed with test exit 0 and the judge rejected the same total with exit 65, matching the baseline. See `guard.diff`, `baseline.log`, `red.log`, and `restored.log` in `verification/leak-byte-guard.7nnMNs/`.

## Hosted control and plant

Hosted verification remains pending. With approval to publish and delete the two temporary branches, cut both from the open PR's head. Dispatch `CI` on each branch so both smoke jobs use the same event and the same source apart from the planted deletion. Record the PR URL, both run URLs, checkout SHAs, smoke job IDs, leak step results, and the plant's byte-bound diagnostic. Run the blocks in the same Bash shell. Branch preparation and dispatch should take seconds apart from commit signing and network delays. Each smoke job has an eight-minute execution limit plus queue time, and the watch commands show progress. [GitHub workflow dispatch](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)

The plant removes `self.history.deinit(self.allocator);` from `destroy` in `src/clap/plugin.zig`. The AppKit smoke creates a plugin through the CLAP factory and calls `destroy` in all 40 cycles. The omitted call leaves a C-allocated history ring of `1 << 18` `f32` samples per cycle, at least 40 MiB across the run against the judge's 1 MiB ceiling. The plant still destroys the editor and instance so the AppKit smoke can finish and the leak step can judge the native report. [Leak instruments](../../notes/leak-instruments.md)

The push preview prints the proposed updates and stops the procedure unless their destinations are exactly the two temporary branch refs.

```bash
set -euo pipefail
repo=cboone/fosforo
fix_branch=fix/editor-leak-gate
[[ "$(git branch --show-current)" == "${fix_branch}" ]]
tree_status="$(git status --porcelain)"
[[ -z "${tree_status}" ]]
control_sha="$(git rev-parse HEAD)"
pr="$(gh pr view "${fix_branch}" --repo "${repo}" --json url,state,isCrossRepository,headRefOid)"
jq -e --arg sha "${control_sha}" '
  .state == "OPEN" and (.isCrossRepository | not) and .headRefOid == $sha
' <<< "${pr}"
jq -r .url <<< "${pr}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
control_branch="plant/156-control-${control_sha:0:12}-${stamp}"
plant_branch="plant/156-native-editor-leak-${control_sha:0:12}-${stamp}"
control_ref="refs/heads/${control_branch}"
plant_ref="refs/heads/${plant_branch}"
git branch "${control_branch}" "${control_sha}"
git switch -c "${plant_branch}" "${control_sha}"
perl -pi -e 's/^    self\.history\.deinit\(self\.allocator\);\n$//' src/clap/plugin.zig
git add -- src/clap/plugin.zig
git commit -S -m 'test: plant an editor history-ring leak'
plant_sha="$(git rev-parse HEAD)"
git switch "${fix_branch}"

[[ "$(git rev-parse "${control_branch}")" == "${control_sha}" ]]
[[ "$(git rev-parse "${plant_sha}^")" == "${control_sha}" ]]
delta="$(git --no-pager diff --no-ext-diff --no-color --numstat "${control_sha}" "${plant_sha}")"
[[ "${delta}" == $'0\t1\tsrc/clap/plugin.zig' ]]
git --no-pager diff --no-ext-diff --no-color "${control_sha}" "${plant_sha}" |
  rg -Fx -- '-    self.history.deinit(self.allocator);'

push_preview="$(git push --dry-run --porcelain --no-follow-tags origin \
  "${control_ref}:${control_ref}" "${plant_ref}:${plant_ref}")"
printf '%s\n' "${push_preview}"
preview_refs="$(awk -F '\t' 'NF > 1 { sub(/^[^:]*:/, "", $2); print $2 }' <<< "${push_preview}" |
  LC_ALL=C sort)"
expected_refs="$(printf '%s\n' "${control_ref}" "${plant_ref}" | LC_ALL=C sort)"
if [[ "${preview_refs}" != "${expected_refs}" ]]; then
  printf '%s\n' 'Push preview must list exactly the control and plant branch refs.' >&2
  exit 1
fi

git push --no-follow-tags origin "${control_ref}:${control_ref}" "${plant_ref}:${plant_ref}"
gh workflow run ci.yml --repo "${repo}" --ref "${control_branch}"
gh workflow run ci.yml --repo "${repo}" --ref "${plant_branch}"
```

Use the run IDs returned by the dispatches. If the IDs are absent, look them up by branch, event and SHA after the runs appear.

```bash
gh run list --repo "${repo}" --workflow ci.yml --event workflow_dispatch \
  --branch "${control_branch}" --commit "${control_sha}" --json databaseId,url
gh run list --repo "${repo}" --workflow ci.yml --event workflow_dispatch \
  --branch "${plant_branch}" --commit "${plant_sha}" --json databaseId,url
```

The control's smoke job and leak step must succeed. Both must fail in the plant, with the byte-bound diagnostic in the smoke log. Check dispatch metadata and the SHA emitted immediately after `git log -1 --format=%H` in each smoke checkout log.

```bash
set -euo pipefail

function verify_dispatch() {
  local run_id="${1}" branch="${2}" sha="${3}" verdict="${4}"
  local run job_id smoke_log

  gh run watch "${run_id}" --repo "${repo}" --compact
  run="$(gh run view "${run_id}" --repo "${repo}" \
    --json event,headBranch,headSha,jobs,status,url,workflowName)"
  job_id="$(jq -er --arg branch "${branch}" --arg sha "${sha}" --arg verdict "${verdict}" '
    select(.workflowName == "CI" and .event == "workflow_dispatch" and .status == "completed"
      and .headBranch == $branch and .headSha == $sha)
    | [.jobs[] | select(.name == "smoke" and .conclusion == $verdict
      and any(.steps[]; .name == "Cycle the editor under leaks" and .conclusion == $verdict))]
    | select(length == 1) | .[0].databaseId
  ' <<< "${run}")"

  smoke_log="$(gh run view "${run_id}" --repo "${repo}" --job "${job_id}" --log)"
  awk -v expected="${sha}" '
    /git log -1 --format=%H$/ {
      if (getline > 0 && $NF == expected) {
        print "Checked out " $NF
        found = 1
      }
    }
    END { exit !found }
  ' <<< "${smoke_log}"
  if [[ "${verdict}" == failure ]]; then
    rg 'smoke-leak-check: [0-9]+ bytes leaked, above the 1048576-byte bound' <<< "${smoke_log}"
  fi
  printf 'Run %s, smoke job %s, leak step %s\n' "$(jq -r .url <<< "${run}")" "${job_id}" "${verdict}"
}

read -r -p 'Control run ID: ' control_run_id
read -r -p 'Plant run ID: ' plant_run_id
verify_dispatch "${control_run_id}" "${control_branch}" "${control_sha}" success
verify_dispatch "${plant_run_id}" "${plant_branch}" "${plant_sha}" failure
```

After recording both outcomes, delete both remote branches and both local refs while on `fix/editor-leak-gate`. Cleanup should take seconds plus network delay.

```bash
set -euo pipefail
[[ "$(git branch --show-current)" == "${fix_branch}" ]]
git push --no-follow-tags origin ":${control_ref}" ":${plant_ref}"
git update-ref -d "${control_ref}" "${control_sha}"
git update-ref -d "${plant_ref}" "${plant_sha}"
```
