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
