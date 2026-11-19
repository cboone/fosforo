# Measurement row parity

Align `scripts/measure-trace` with `src/gpu/measure.zig` for continuous row
positions and inclusive period-band membership. Keep the existing energy
threshold and all rendering unchanged.

## Plan

1. Reproduce the centre offset and isolate the exact-tie comparison using
   generated row arrays. Compare executed helpers across Python and Zig.
2. Extract script geometry and period helpers, use them in the CLI, and compare
   derived results against Zig helpers over odd/even heights, dark columns and
   band boundaries. Use the existing measurement implementation as prior art.
3. Plant the half-pixel and comparison regressions with the checked runner.
4. Run the full structural and focused review loops, both trims, covering checks
   and final lint. Tidy signed commits with exact tree equality, then open a
   ready PR. Never merge.

## Boundaries and evidence

Worktree-local setup is authorized by the answer relayed by TOOLING from the
Overnight worker setup Inbox thread. `npm ci` completed; Zig 0.16.0 and Ruff
0.16.5 archives were checksum-verified against upstream metadata. No global
installation was changed.

Baseline `zig build test` exited 0. Local evidence is under
`verification/130-tools/`; the initial stop report remains in the worker mailbox.
The available verification directories contain no existing capture, so generated
arrays provide the parity cases authorized by the brief. Capture re-reading is
unavailable and no published capture measurement is claimed.

## Review counts

Structural: one Nit round, ended: fixes changed no behavior. Focused: one Nit
round, resumed after TOOLING’s approved coverage-guidance class audit, then
ended: fixes changed no behavior. Trims: one comment pass and one prose pass. See the
[ledger](2026-11-19-measurement-row-parity-ledger.md) for findings and evidence.
