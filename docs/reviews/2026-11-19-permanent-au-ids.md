# Audio Unit identifier review

The wrapper CI job checks the generated Audio Unit plist against the three permanent codes. That job builds the same component as the worktree wrapper build. CLAP coverage waits for the identifier rename in [fosforo issue 137](https://github.com/cboone/fosforo/issues/137).

## Review rounds

- Structural Nit round, read-only Codex anti-patterns and four cleanup aspects: ended: fixes changed no behavior. The anti-pattern reviewer labeled the type plant patch Important because Git could not apply it and the other plants would be skipped. Accepted as Important and added trailing context. The fix is limited to a test fixture. The cleanup reviewers raised no findings.
- Focused Nit round, read-only code, errors, tests and comments aspects: clean at Nit. The branch adds no types.
- One trim round, read-only comments and prose: shortened the workflow comment and kept the issue reference. The prose pass proposed no edits.

The structural and focused runs used GPT-6.1-Sol at high effort and the trim run used low effort. Each scope comparison exited 0, with unchanged scope and empty changed-path lists inside and outside the scope.

## Assertion evidence

- The workflow comment, changelog and build plan describe independent comparisons against the built plist. Each patch changes a CMake code in isolation. The plant checker runs the exact workflow assertion after the wrapper build, then repeats it after restoration.
- The shell comment about preserving trailing newlines describes the exact comparison. A scratch copy of the built plist with a newline appended to the type was rejected by that same assertion.
- The build plan records why the codes are permanent. The patches test the build output rather than host project loading.
- The CLAP follow-up comment names the pending rename. This branch changes no identifier declaration.
