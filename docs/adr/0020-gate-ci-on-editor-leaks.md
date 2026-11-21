# 0020. Fail CI when the editor leak check fails

Accepted on 2026-11-21. Supersedes [ADR 0013](0013-gui-smoke-harness-as-a-build-step.md) on whether the leak check fails CI.

The 40-cycle leak check fails the smoke job on any unsuccessful verdict. The smoke summary still records the verdict, leaked bytes when available, and runner image. A failed AppKit smoke step skips the leak check.

The judge can flag framework allocations because some class prefixes apply to both the editor and macOS frameworks. The five latest main runs inspected for [issue 156](https://github.com/cboone/fosforo/issues/156), ending at [run 44573514555](https://github.com/cboone/fosforo/actions/runs/44573514555), reported successful leak outcomes across two runner images. The step runs once per job.
