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

## CI plant, after push

Hosted verification remains pending. First check the unplanted PR's own `CI` run on the exact local head. The `smoke` job and its `Cycle the editor under leaks` step must succeed. Begin once the PR's smoke check has completed. Record the PR URL, head SHA, run URL and smoke job ID with the plant result. Run the blocks in the same Bash shell so the verified head and plant branch carry forward.

In `src/clap/plugin.zig`, remove `self.history.deinit(self.allocator);` from `destroy`. The AppKit smoke creates a plugin through the CLAP factory and calls `destroy` in all 40 cycles. The factory allocates each history ring with `std.heap.c_allocator`. The omitted call leaves `1 << 18` `f32` samples allocated per cycle, at least 40 MiB across the run against the judge's 1 MiB ceiling. The plant still destroys the editor and instance, so the AppKit smoke can finish normally and the leak step can judge the native report. The same omission was previously measured at 40 cycles. [Leak instruments](../../notes/leak-instruments.md)

Keep the green check and plant creation in one block. The branch name includes the verified SHA, and the signed plant commit starts at that SHA.

```bash
set -euo pipefail
repo=cboone/fosforo
fix_branch=fix/editor-leak-gate
test "$(git branch --show-current)" = "${fix_branch}"
tree_status=$(git status --porcelain)
test -z "${tree_status}"
control_sha=$(git rev-parse HEAD)
pr=$(gh pr view "${fix_branch}" --repo "${repo}" \
  --json url,state,isCrossRepository,headRefOid,statusCheckRollup)
check_url=$(jq -er --arg sha "${control_sha}" '
  select(.state == "OPEN" and (.isCrossRepository | not) and .headRefOid == $sha)
  | [.statusCheckRollup[] | select(.workflowName == "CI" and .name == "smoke")]
  | select(length == 1)
  | .[0] | select(.status == "COMPLETED" and .conclusion == "SUCCESS") | .detailsUrl
' <<< "${pr}")
[[ "${check_url}" =~ ^https://github\.com/cboone/fosforo/actions/runs/([0-9]+)/job/([0-9]+)$ ]]
control_run_id=${BASH_REMATCH[1]}
control_job_id=${BASH_REMATCH[2]}
control_run=$(gh run view "${control_run_id}" --repo "${repo}" --json event,headSha,jobs,name,status,url)
jq -e --arg sha "${control_sha}" --argjson job_id "${control_job_id}" '
  .name == "CI" and .event == "pull_request" and .status == "completed" and .headSha == $sha
  and any(.jobs[]; .databaseId == $job_id and .name == "smoke" and .conclusion == "success"
    and any(.steps[]; .name == "Cycle the editor under leaks" and .conclusion == "success"))
' <<< "${control_run}"
printf 'Green control for %s at %s\n' "$(jq -r .url <<< "${pr}")" "${control_sha}"
printf 'Run %s, smoke job %s\n' "$(jq -r .url <<< "${control_run}")" "${control_job_id}"

plant_branch="plant/156-native-editor-leak-${control_sha:0:12}"
git switch -c "${plant_branch}" "${control_sha}"
perl -pi -e 's/^    self\.history\.deinit\(self\.allocator\);\n$//' src/clap/plugin.zig
git add -- src/clap/plugin.zig
git commit -S -m 'test: plant an editor history-ring leak'
git switch "${fix_branch}"
```

After approval to publish and delete the throwaway branch, dispatch `CI` on its exact commit. Branch pushes trigger CI only on `main`, so use `workflow_dispatch`. Use the returned run ID, or look it up by branch, event, and SHA once the run appears.

```bash
set -euo pipefail
plant_sha=$(git rev-parse "${plant_branch}")
test "$(git rev-parse HEAD)" = "${control_sha}"
test "$(git rev-parse "${plant_sha}^")" = "${control_sha}"
git push origin "${plant_branch}"
gh workflow run ci.yml --repo cboone/fosforo --ref "${plant_branch}"
gh run list --repo cboone/fosforo --workflow ci.yml --event workflow_dispatch \
  --branch "${plant_branch}" --commit "${plant_sha}" --json databaseId,url
```

The smoke job has an eight-minute execution limit plus queue time. The watch command displays progress. Record the run URL, smoke job ID, and byte-bound verdict from `Cycle the editor under leaks`. The job and that step must both fail, and the failed step must contain the byte-bound diagnostic.

```bash
set -euo pipefail
printf 'Workflow run ID: '
read -r run_id
gh run view "${run_id}" --repo "${repo}" --json event,headSha,headBranch |
  jq -e --arg sha "${plant_sha}" --arg branch "${plant_branch}" '
    .event == "workflow_dispatch" and .headSha == $sha and .headBranch == $branch
  '
gh run watch "${run_id}" --repo cboone/fosforo --compact
smoke_job_id=$(gh run view "${run_id}" --repo cboone/fosforo --json jobs | jq -er '
  .jobs[] | select(.name == "smoke" and .conclusion == "failure")
  | select(any(.steps[]; .name == "Cycle the editor under leaks" and .conclusion == "failure"))
  | .databaseId
')
gh run view "${run_id}" --repo cboone/fosforo --job "${smoke_job_id}" --log-failed |
  rg 'smoke-leak-check: [0-9]+ bytes leaked, above the 1048576-byte bound'
gh run view "${run_id}" --repo cboone/fosforo --json url --jq .url
printf 'Smoke job ID: %s\n' "${smoke_job_id}"
```

After recording the result, delete the throwaway branch from the remote and remove the local ref while on `fix/editor-leak-gate`.

```bash
set -euo pipefail
test "$(git branch --show-current)" = fix/editor-leak-gate
git push origin --delete "${plant_branch}"
git update-ref -d "refs/heads/${plant_branch}" "${plant_sha}"
```
