# Realign the build plan, the agent docs, and the tracker

## Context

Phase 3 has moved fast. Nine issues closed in under two weeks (#55, #64, #63, #22, #51, #61, #60, #56, and #57 about to), and five arrived while that happened (#77, #79, #80, #83, #84). The build plan has been maintained per issue, so most of it is current, but the parts that describe *the set of open work* rather than a single landed change have drifted, because no single issue owns them.

Three things are now wrong or missing in ways a reader would act on:

- **#62 is in no working order at all**, while the phase's own exit criteria require it. "Stable under sample-rate change" is exactly the aliasing #62 fixes, and #62 appears in the issue table and then in none of the sequencing prose.
- **The milestone rule contradicts the practice.** The plan says non-steps stay off milestones; #62, #77, #79 and #80 are all on the Phase 3 milestone with step "none".
- **The phase is described as running serially** when three streams ran concurrently last week, and the paragraph immediately after that claim explains why #22 made it untrue for the CLAP.

Alongside those, the ADR table stops at 0017 while 0018 and 0019 are accepted, the resource table names only closed issues, and #83 and #84 are referenced by no living document at all — only by #57's own plan, which becomes a historical record the moment it merges.

The intended outcome is one pass that leaves the plan, `AGENTS.md`, and the tracker describing the same project, and that replaces the "runs serially" claim with an explicit statement of what can run beside what. This is bookkeeping, not architecture: no ADR is superseded and no decision is reopened.

## Branch strategy

Branch from `feature/beam-as-quads` rather than `main`, so this reviews as a stacked PR on top of #57 and merges after it.

That branch is already complete and already rewrites four of the hunks this pass touches: the #57 table row, the working-order paragraph, `AGENTS.md`'s Current state section, and amendments to ADRs 0007, 0013 and 0019. Branching off `main` would guarantee a conflict in exactly the two paragraphs both changes rewrite, and would also force this pass to describe #57's outcome as a prediction when the branch beside it has already measured it.

**Nothing here is in scope for #57's branch itself.** That branch is one issue's work under the plan's own one-issue-one-PR rule; this is a tracker sweep and belongs in its own commit series.

## Already handled by #57, and deliberately not repeated here

Read these before editing, so the pass does not re-fix them:

- The #57 row in the phase 3 issue table, and its status moving to Done.
- The working-order sentence, which becomes "…then **#57** — all nine done — then **#58**, then **#59** behind it."
- `AGENTS.md`'s Current state, the "next issue" pointer, the line-width gotcha, the rail gotcha, and the centre-line half-pixel answer.
- ADR 0007's beam-as-geometry amendment, and the ADR 0013 and 0019 amendments recording that a frame can now deposit twice on one pixel.

## Work

### 1. The build plan

`docs/plans/todo/2026-07-25-repo-foundation-and-phased-build-plan.md`.

| What is wrong                                                                         | Fix                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "Five more were decided during execution", table stops at 0017                        | "Seven more"; add 0018 (Phase 2) and 0019 (Phase 3), matching `docs/adr/README.md`, which is already correct                                                                              |
| "Seven open issues sit on no milestone", then names #34, #30, #51, #65, #53, #69, #72 | Five: #69, #65, #53, plus #34 and #30 in the risks table. #51 and #72 closed; #83 and #84 acquire milestones under this plan                                                              |
| "Phase 3's issues are filed, #55 through #62"                                         | The set is no longer a range. Name it, and say that #77, #79, #80 and #83 were filed during the phase rather than at its start                                                            |
| Phase 3 heading reads "(next)"                                                        | "(in progress)"                                                                                                                                                                           |
| Issue table has no rows for #79, #80, #83                                             | Add three rows with step "none", following #77's and #62's existing shape                                                                                                                 |
| "The consequence is that this phase runs serially"                                    | Replace with the lane table below. The following paragraph already explains why #22 made this untrue for the CLAP; the two currently contradict each other                                |
| Resource table names #55, #63 and #64, all closed, and omits #65                      | Name the live occupants of each resource, and add #65, which needs Logic but not the install path                                                                                         |
| "#30, which touches no code and runs nothing on this machine"                         | The conclusion is right and the reason is wrong: #30 re-runs the three release scripts, including notarization. It contends for none of this phase's resources, which is the actual point |
| Exit criteria say "stable under sample-rate change" with no issue attached            | Say that #62 is what closes it, which is also what places #62 in the working order                                                                                                        |
| Working order omits #62, #77, #79, #80 and #83                                        | Extend it per the sequence below                                                                                                                                                          |

Two of these are worth stating as findings rather than as edits, because they change what the phase's remaining work is:

- **#62 is a phase-3 exit criterion, not a stray.** Nothing else in the phase makes the display honest above 48 kHz, and the criterion has been written down since the plan was first drafted.
- **#77 is overdue rather than upcoming.** Its own body says it "bites first at #57", #57 has landed, and #58 will move bindings again if velocity weighting adds a uniform. It is the one issue whose urgency this pass discovers rather than records.

### 2. Milestones

Per the decision that a milestone marks what must close before the phase's exit criteria are met, rather than what is a numbered step:

- Restate the rule in the "How work is tracked" section, so the label has one meaning.
- #83 moves onto **Phase 3**. It is a fidelity change measured against #57's own banding finding, so it sits inside "looks like hardware".
- #84 moves onto **Phase 4**. Its body already says so, and it needs a host headroom measurement that may close it outright.
- #62, #77, #79 and #80 stay where they are, now consistent with the restated rule rather than in spite of it.
- Note that Phase 4 acquiring an issue does not break the just-in-time filing rule: that rule forbids manufacturing a backlog, and #84 was filed reactively from a finding.

### 3. The working order, and what parallelizes

This is the substantive deliverable. Replace the serial claim with three lanes plus a sequence.

| Lane                        | What it needs                        | Open issues                       |
| --------------------------- | ------------------------------------ | --------------------------------- |
| Host, GPU and window server | REAPER or Logic, plus `smoke-appkit` | #58, #59, #79, #83, #53, #34, #69 |
| Device, no window           | `smoke-gpu` and `smoke-trace` only   | #77, #80                          |
| Neither                     | Compiling and `zig build test`       | #62, #30                          |

`#65` is its own case and should be recorded as one: its decisive check is a positive control on other vendors' Audio Units in Logic, which needs Logic but never loads this plugin, so it does not contend for the install path.

The sequence, with the parallel set named explicitly:

1. **#58**, next, per #57's branch. Host lane.
2. Beside it, in other lanes: **#77** (overdue, and #58 may move bindings again), **#62**'s algorithm half in the new `src/dsp/decimate.zig`, **#30**, **#65**.
3. **#79** behind #58, and likely closing as *covered* rather than fixed: its body argues velocity weighting should make the transport-stop line dim by construction. Reads together with #53.
4. **#59** behind #58.
5. **#62**'s wiring with or after #59, which is where the point count stops being bounded by the sample rate.
6. **#83** after #58 and #59, so the banding measured is the banding that ships.
7. **#84** in phase 4, gated on the headroom measurement.
8. **#69** wherever suits, host lane. **#34** gated on a second display rather than on anything here.

Two collisions to record so they are not discovered mid-branch:

- **#80 and #58 both edit `src/smoke.zig`.** Different lanes, so they can run at once; whichever lands second rebases.
- **#62 collides with nothing.** #57's branch touches no file under `src/dsp/`, verified rather than assumed.

### 4. Issue bodies

Edit in place with a marked `> **Rewritten.**` note, following #80's own precedent, which is the house style for this.

- **#58**: "Depends on step 4" is satisfied. Record what it inherits from #57 rather than what it waits for: the biweight profile, `TraceUniforms.density` and why that is *not* velocity weighting, and the 2.6133 deposits per pixel that retired the one-deposit premise. Add #79's claim on it.
- **#59**: same dependency correction; note that it now upsamples into real geometry.
- **#62**: point its sequencing at #59 explicitly, and record that it is a phase-3 exit criterion.
- **#77**: note that #57 has landed, so its trigger condition is met.
- **#83**, **#84**: record the milestone decision and its reasoning.

### 5. `AGENTS.md`

Two gaps confirmed by grep rather than assumed. Neither subject has a bullet today:

- **Aliasing above 48 kHz** (#62). The gotchas cover the trace floor and the rail, and say nothing about a window holding more samples than the drawable has pixels.
- **The transport-stop line** (#79). A visible artifact anyone will hit within a minute of playing a file, currently recorded only in the issue.

Also fix the issue pointers that are stale once this pass lands, and check whether `checkResolve`'s off-by-one under #57 wants a pointer at #83. That last one depends on what #57's branch already wrote, so read it after merging rather than planning the wording now.

## Verification

No code changes, so the checks are about the documents saying true things.

```bash
# every issue number the plan and AGENTS.md reference, with its real state
grep -ohE 'issues/[0-9]+' docs/plans/todo/*.md AGENTS.md | cut -d/ -f2 | sort -un \
  | xargs -I{} gh issue view {} --json number,state,milestone \
      --template '{{.number}} {{.state}} {{if .milestone}}{{.milestone.title}}{{else}}none{{end}}'"$(printf '\n')"

# the milestone sets, after the moves
gh issue list --milestone "Phase 3: the phosphor renderer" --state open --json number,title
gh issue list --milestone "Phase 4: triggering" --state open --json number,title
gh issue list --state open --search 'no:milestone' --json number,title   # expect exactly #69 #65 #53 #34 #30

markdownlint-cli2 "docs/**/*.md" "*.md"    # CHECK MODE ONLY, see below
typos
```

Then read for the three claims this pass exists to fix, since no tool checks them: that every open phase-3 issue appears in both the issue table and the working order; that the lane table's membership matches what each issue's verification section actually needs; and that the non-milestone count in the prose equals what `no:milestone` returns.

**Never run `markdownlint --fix` here.** It ignores its file argument and rewrites every Markdown file in the tree, and it has previously edited a completed plan under `docs/plans/done/` unasked. Fix findings by hand.

The CI jobs that matter are `typos`, which has no `paths-ignore` and so actually runs on documentation, and nothing else: `ci.yml` ignores `*.md` and `docs/**` on both triggers, so a docs-only branch dispatches almost no work.

## What this landed

Everything above, plus two things the pass found rather than planned.

**The build plan.** The ADR table completed to seven with 0018 and 0019; the milestone rule restated as *what must close before the phase's exit criteria are met*, which is what makes #62, #77, #79 and #80 legible on the milestone; the non-milestone set corrected from a stale seven to six, its composition rebuilt; the "#55 through #62" range replaced; the heading moved to "(in progress)"; three rows added to the phase 3 table; "stable under sample-rate change" attached to #62; and the "runs serially" claim replaced by three lanes plus a sequence that places every open issue. Verified mechanically: every open phase 3 issue now appears in both the issue table and the working order, which none of #62, #79, #80 or #83 did before.

**The tracker.** #83 to Phase 3, #84 to Phase 4. Six issue bodies rewritten with the marker (#58, #59, #62, #77, #83, #84). The Phase 3 milestone reads 8 open and will read 7 when #57's PR closes it, matching the table.

**Two findings.** #59 quoted a row-104 measurement taken with the topmost-lit-pixel estimator #57 replaced, so it is half a pixel from comparable; the body now says to re-measure, and records that the point it was making survives because it is about sample values rather than rasterization. And #62 gained a third interaction that did not exist when it was filed: `TraceUniforms.density` derives from the raw sample count, decimation changes exactly that count, and the two corrections would otherwise fight over the same high-sample-rate case.

**`AGENTS.md`** gained bullets for the sample-rate alias and the transport-stop line, neither of which had one, plus the `markdownlint` invocation and its `--fix` trap.

**[#85](https://github.com/cboone/fosforo/issues/85), filed.** `.markdownlint-cli2.jsonc` pins `MD060` to `aligned` and nothing runs it: 0 findings on `main` against 129 on a branch in flight, all table alignment. That is the state `typos.toml` was in before #28. The two findings in the build plan itself were fixed here as a side effect of re-padding tables this pass was already editing; the rest belong to the branch that introduced them.

## Out of scope

- **Any code change.** If a gotcha turns out to describe behaviour that has changed, file it rather than fixing it here.
- **Reopening a decision.** ADR 0019 is under real pressure from #84, which says so itself and proposes a new ADR fixing the transfer function in nits. That is #84's work, not this pass's.
- **Filing phase 4 issues.** The just-in-time rule holds; #84 is on that milestone because it was filed from a finding, not because phase 4 is being planned.
- **`docs/plans/done/`.** Completed plans are historical records and stay as written, including where they predicted something that did not happen.
