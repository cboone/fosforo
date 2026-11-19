# CI installer migration review

The branch replaces five hand-written CI installers with the shared
`install-pinned-tool` action at the `v5.0.0` commit. Both ShellCheck calls share
the existing version and checksum. Review used `origin/main` at
`d7a8e451c71192a044fd451ad74010436fe35874`.

## Structural review

The Nit round ran the anti-patterns and four cleanup reviewers on `86f9ea2`
using Codex in read-only mode. The round ended: fixes changed no behavior.

| Review label                      | Severity | Finding and disposition                                                                                                       | Review again         |
| --------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| `nit`                             | Nit      | The pin comment said every pair served two jobs. Corrected the comment to describe the two ShellCheck consumers.              | No behavior changed. |
| `suggestion` (reuse and altitude) | Nit      | Both jobs specify the ShellCheck asset layout. Recorded the maintenance cost and kept the direct calls proposed in the issue. | No edit.             |

## Focused review

The Nit round ran the code, errors, tests and comments aspects on `33b2e04`
using Codex in read-only mode. The migration adds no type definitions. The
round finished clean at Nit.

## Trims and scope proof

One read-only trim round on `33b2e04` shortened the comment about actionlint
skipping shell checks when shellcheck is missing. The wording pass left the unrelated
shell job timing comment in place and made no changes to the CI note.

Both review rounds and the trim round captured scope before and after all
reviewers finished. Each comparison exited 0, returned `scope_changed` false
and listed zero changed paths inside or outside the original scope.
