# Measurement row parity ledger

The script now uses pixel-centred rows and an inclusive period band. Rendering
and the energy threshold are unchanged.

## Reviews

Structural Nit: frozen `14f32b2`, base `6398519`. Anti-patterns and four cleanup
angles ran independently in read-only Codex, `gpt-6.1-sol`, high effort, window 872000. All five completed; scope unchanged. Evidence: worker mailbox
`structural-nit.SXsy35/`, including schemas, prompts, hashes, logs and outputs.
Helper snapshots: worker mailbox `helpers/hashes.json`.

| Finding                      | Reviewer label | Severity and impact                           | Take or record                                                     | Review again |
| ---------------------------- | -------------- | --------------------------------------------- | ------------------------------------------------------------------ | ------------ |
| Lower rail unchecked         | nit            | Nit: missing independent boundary test        | Take: compare mirrored Zig rail; add plant                         | Tests only   |
| Ruff coverage guidance stale | nit            | Nit: obsolete discovery guidance              | Take: update workflow, configuration, contributing and living note | Prose only   |
| Capture prerequisite stale   | nit            | Nit: contradicts generated-array verification | Take: update active build plan                                     | Prose only   |
| Repeated peak calculation    | suggestion     | Nit: small allocation in an offline tool      | Record: optional peak parameter adds a parallel helper path        | No edit      |

Structural: one Nit round, **ended: fixes changed no behavior**.
Focused: one Nit round at `0e71a3d`, **stopped: recurring defect**. All five
aspects completed with unchanged scope; evidence: worker mailbox
`focused-nit.9zRz9w/`. Code, errors, tests and types found no findings. Comments
reported a `suggestion`: Ruff formatter output reports a count, so the revised
guidance cannot establish named-file coverage from that output. Severity: Nit,
inaccurate instructions. Take or record: take, pending the conductor’s class
call. Review again: prose-only fix would change no behavior.

Proposed recurring mechanism: coverage instructions rely on tool-output details
not actually emitted. Sites named by the reviewer: `.github/workflows/ci.yml`,
`CONTRIBUTING.md`, `docs/notes/linters.md`. TOOLING approved the
mechanism and continuation. The audit below completed before fixing the guidance.

Focused resumed without another round after the approved prose-only class fix:
**ended: fixes changed no behavior**. Counts remain structural 1, focused 1.

Trims: one comment pass and one prose pass at `9192eae`, read-only
`gpt-6.1-sol`, low effort, window 872000; both completed with unchanged scope.
Evidence: worker mailbox `trims.bopxO5/`. Accepted workflow/configuration comment
trims and the contributing sentence trim. Declined the build-comment rewrite:
the original leads with the inputs supplied to the step and retains its
constraint; the proposed reason-first wording adds no clarity. Corrected the
capture note’s inaccurate “below” reference. Existing capture history was not
refreshed; no capture was available.

Final verification receipt: `verification/130-final-gate/receipt.json`.
The receipt and TOOLING handoff carry the final check results; this ledger
does not infer verification from a pending or failed run. Copilot: 0; never requested.

## Proof and limits

- Centre, rails and band: executed Python results compared with Zig helpers.
- Periods: generated lit rows, dark gaps, neighbours and exact ties compared with
  `measure.periods`; CLI output checked against script helpers.
- Assertions: deliberately wrong expected results must fail; judge-removal plants
  exercise those checks.
- Original/corrected combined period counts agree on 285 generated lit cases.
  Reproduction: `verification/130-tools/rounding-reproduction-3.txt`.
- No existing capture was available. No published capture result is corrected.
- First plant run failed its verdict matcher on Zig’s `0 skipped` summary;
  no plant credit. Narrowed skip markers preserve refusal of real skips.
  Evidence: `verification/130-plant-run-1/results.json`.

<!-- checked-plants:start -->

## Verified plants and controls

plant zig-centre-half-pixel: named assertion reached; red exit 1; restored; green exit 0.

plant python-centre-half-pixel: named assertion reached; red exit 1; restored; green exit 0.

plant python-period-band: named assertion reached; red exit 1; restored; green exit 0.

plant zig-period-band: named assertion reached; red exit 1; restored; green exit 0.

plant python-exact-tie: named assertion reached; red exit 1; restored; green exit 0.

plant python-rail-half-pixel: named assertion reached; red exit 1; restored; green exit 0.

plant cli-centre-half-pixel: named assertion reached; red exit 1; restored; green exit 0.

plant cli-period-counter: named assertion reached; red exit 1; restored; green exit 0.

plant python-bottom-half-pixel: named assertion reached; red exit 1; restored; green exit 0.

plant judge-centre: named assertion reached; red exit 1; restored; green exit 0.

plant judge-rail: named assertion reached; red exit 1; restored; green exit 0.

plant judge-bottom: named assertion reached; red exit 1; restored; green exit 0.

plant judge-band: named assertion reached; red exit 1; restored; green exit 0.

plant judge-periods: named assertion reached; red exit 1; restored; green exit 0.

control comment-control: green control verified; control exit 0; restored; green exit 0.

Evidence: `/Users/ctm/Work/projects/tooling/fosforo/130-measurement-row-parity/verification/130-plant-run-2/results.json`.

<!-- checked-plants:end -->

## Approved class audit

TOOLING approved: coverage instructions rely on tool output the tool does not
actually emit. Every changed file was searched in full; results are in
`verification/130-tools/class-audit.json`. No behavioral check changed.

The following claims map to observed Ruff 0.16.5 output:

- Formatter summary is a count: `ruff format --check .`,
  `verification/130-tools/ruff-format-observed.txt` (`2 files already formatted`).
- Discovery names both scripts: `ruff check --show-files`,
  `verification/130-tools/ruff-files-observed.txt`. The output also lists the
  configuration, so no exact discovery count is prescribed.
- Default discovery without project configuration finds the .py test but omits
  the extensionless script: `ruff check --show-files --isolated scripts`,
  `verification/130-tools/ruff-isolated-observed.txt`. An empty extend-include
  CLI override did not remove the configured glob, so that attempt is not proof.

| Site checked                                                           | Result                                                                   |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `.github/workflows/ci.yml`                                             | Corrected formatter/discovery claims and Python-job coverage description |
| `CHANGELOG.md`                                                         | No further instance of the approved mechanism                            |
| `CONTRIBUTING.md`                                                      | Corrected formatter/discovery guidance                                   |
| `build.zig`                                                            | No further instance of the approved mechanism                            |
| `docs/notes/linters.md`                                                | Corrected formatter/discovery guidance                                   |
| `docs/notes/measuring-a-capture.md`                                    | No further instance of the approved mechanism                            |
| `docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`  | No further instance of the approved mechanism                            |
| `docs/plans/todo/2026-11-19-measurement-row-parity-ledger.md`          | No further instance of the approved mechanism                            |
| `docs/plans/todo/2026-11-19-measurement-row-parity.md`                 | No further instance of the approved mechanism                            |
| `measurement-plants.json`                                              | No further instance of the approved mechanism                            |
| `ruff.toml`                                                            | Corrected the claim that missing include would discover no Python        |
| `scripts/measure-trace`                                                | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/check.sh`                       | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/cli-centre-half-pixel.patch`    | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/cli-period-counter.patch`       | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/comment-control.patch`          | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/judge-band.patch`               | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/judge-bottom.patch`             | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/judge-centre.patch`             | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/judge-periods.patch`            | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/judge-rail.patch`               | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/python-bottom-half-pixel.patch` | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/python-centre-half-pixel.patch` | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/python-exact-tie.patch`         | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/python-period-band.patch`       | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/python-rail-half-pixel.patch`   | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/setup.sh`                       | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/zig-centre-half-pixel.patch`    | No further instance of the approved mechanism                            |
| `scripts/plants/measurement-row-parity/zig-period-band.patch`          | No further instance of the approved mechanism                            |
| `scripts/test-measure-trace.py`                                        | No further instance of the approved mechanism                            |
| `src/gpu/measure.zig`                                                  | No further instance of the approved mechanism                            |
| `src/measure_parity.zig`                                               | No further instance of the approved mechanism                            |
