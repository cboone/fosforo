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

## CI plant, after push

Hosted verification is pending approval to push the throwaway branch to `cboone/fosforo`, dispatch CI, and delete the remote branch after recording the result. CI on branch pushes is limited to `main`, so this plant uses `workflow_dispatch`.

In `src/clap/plugin.zig`, remove `self.history.deinit(self.allocator);` from `destroy`. The AppKit smoke creates a plugin through the CLAP factory and calls `destroy` in all 40 cycles. The factory allocates each history ring with `std.heap.c_allocator`. The omitted call leaves `1 << 18` `f32` samples allocated per cycle, at least 40 MiB across the run against the judge's 1 MiB ceiling. The plant still destroys the editor and instance, so the AppKit smoke can finish normally and the leak step can judge the native report. The same omission was previously measured at 40 cycles. [Leak instruments](../../notes/leak-instruments.md)

Prepare the signed plant commit from the fix branch's head. If the plant branch has already been prepared, use it for the hosted commands below.

```bash
set -euo pipefail
git switch -c plant/156-native-editor-leak fix/editor-leak-gate
perl -pi -e 's/^    self\.history\.deinit\(self\.allocator\);\n$//' src/clap/plugin.zig
git add -- src/clap/plugin.zig
git commit -S -m 'test: plant an editor history-ring leak'
git switch fix/editor-leak-gate
```

After approval, publish the branch and dispatch `CI` on its exact commit. Use the returned run ID, or look it up by branch, event, and SHA once the run appears.

```bash
set -euo pipefail
plant_branch=plant/156-native-editor-leak
plant_sha=$(git rev-parse "${plant_branch}")
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
test "$(gh run view "${run_id}" --repo cboone/fosforo --json headSha --jq .headSha)" = \
  "$(git rev-parse plant/156-native-editor-leak)"
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
plant_branch=plant/156-native-editor-leak
plant_sha=$(git rev-parse "${plant_branch}")
test "$(git branch --show-current)" = fix/editor-leak-gate
git push origin --delete "${plant_branch}"
git update-ref -d "refs/heads/${plant_branch}" "${plant_sha}"
```
