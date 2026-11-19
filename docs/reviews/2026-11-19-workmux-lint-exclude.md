# Workmux Markdown exclusions

## Scope

For [the prompt-file lint issue](https://github.com/cboone/fosforo/issues/140), add `.workmux/**` to markdownlint-cli2 and `.workmux/` to Prettier. Keep Git exclusions unchanged. Use the config-only small-change path.

Current main at `a66c659` still includes prompts in both tools. No existing branch or PR covers the fix. The two existing tool ignore lists are the extension points; no new tool is needed.

## Verification procedure

Install locked Node dependencies with `npm ci`. Create an untracked `.workmux/PROMPT-140-check.md` with no heading and trailing whitespace. Check Markdown lint, Prettier file information, and byte preservation through `npm run format`. Compare lint file counts with and without the sample. Temporarily remove each exclusion to verify its check detects the regression, restoring each configuration afterward. Temporarily append a skipped heading level to tracked `README.md` and verify MD001 still fails, then restore it byte for byte.

Final evidence, including input-bound receipts and command output, lives in the worker mailbox evidence directory. No sample prompt or capture is committed.

## Review ledger

One small-change review round is planned with code, tests and comments aspects using standalone read-only Codex, `gpt-6.1-sol`, high effort, 872000 context. Error handling and types are unchanged; simplify is not selected. Capture scope before and after all reviewers stop in one strict call and require an unchanged comparison. Record findings and the end state after the round.

Run `lint-and-fix --no-push` afterward: Prettier writes Markdown, then markdownlint-cli2 checks only, as required by root instructions. Preserve historical exclusions. Tidy to signed logical commits with an exact-tree comparison, then push and open a ready PR. Never merge.

Round 1: code, tests and comments completed with no findings; clean at Nit. Scope comparison exited 0 with `scope_changed: false`, `changed: []`, and `outside_scope: []`. Review artifacts: `/tmp/fosforo-140-review.I57Nxu`. The shell fixture and two removal patches subsequently encode the documented verification procedure; these test-only additions change no repository tool behavior and require no further round under the Findings rule.
