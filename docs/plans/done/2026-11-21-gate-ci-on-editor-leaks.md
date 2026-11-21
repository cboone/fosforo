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

## CI green control

The local gate check runs the workflow step's exact shell against the real judge. The editor leak and tolerated-failure policy plants went red, as did the zero-leak, singular and scaled report fixtures in the judge tests. All checks returned to green after restoration.

The PR's own CI run serves as the green control for the hosted leak step.

## Workflow wiring check

A static check of `.github/workflows/ci.yml` confirms that the hosted leak step is wired to fail the merge path:

1. **No `continue-on-error`.** Neither the `smoke` job nor the "Cycle the editor under leaks" step carries `continue-on-error`. The remaining mentions are in comments.
2. **No skipping condition.** Neither the step nor the job has an `if:`. The step is skipped only after an earlier smoke step fails, and the job is already red in that case. The trigger's `paths-ignore` skips documentation-only changes (`*.md`, `docs/**`, `LICENSE` and agent instructions). That's a known, separate gap.
3. **The exit code reaches the job.** The step sets `pipefail` before piping `zig build smoke-leaks` through `tee`, so the judge's nonzero exit fails the step and the job.
4. **A red check stops a merge.** The `main` rulesets ("Main" and "PRs") enforce only the deletion, non-fast-forward and pull request rules, with no required status checks. The merge procedure for this repository supplies the gate instead: every merge waits on `gh pr checks` passing, so a red leak check blocks it.
