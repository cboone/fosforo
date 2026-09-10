# Repair the drift recent work left

## Context

578 commits have landed recently, closing #51, #55 through #61, #77, #89 through #97, #99, #106, #117, #118 and #119. Each one landed its own documentation with it, which is the rule this project works to. What no single issue owns is the class of damage that only shows up **across** issues: a figure corrected where the author noticed it and left standing in four other files, a `path:line` that a neighbouring merge moved, a present-tense sentence that a later issue outran, a constant restated in a fifth place that no check reads.

That class is not hypothetical here. `.github/docs.instructions.md:16` exists because #96 corrected the hot core's one-deposit reading in one file and left it in four others. This is that sweep, run deliberately rather than incidentally.

**The intended outcome is that no living document says something an agent would act on and be wrong.** Three sources of truth are currently wrong about their own subject: `README.md` says the shipped feature does not exist, `CONTRIBUTING.md` recommends the one workflow `AGENTS.md` forbids, and the build plan's phase table — the file `AGENTS.md:11` declares authoritative — marks a landed issue `Open`.

**Scope boundary.** This branch is drift-only. Two genuine code defects were found and they are filed as issues rather than fixed here, because phase 3's rule is that an issue is one complete piece of work with its code and its verification in one branch, and a vacuity guard is worth exactly as much as the plant that proves it discriminates.

### Method

Three parallel audits (documentation, Zig source, build/CI/shell), each finding cross-checked against the code before it entered this plan. Every mechanical check in the repository is **already green**: `shfmt -d`, `shellcheck`, `actionlint`, `typos`, `ruff`, Prettier and `markdownlint-cli2` all report zero. Everything below is drift no configured check can see, which is why it accumulated.

**One audit finding was disproved and is recorded so it is not re-reported.** `docs/notes/ci-workflows.md:5` was flagged as claiming `ci.yml`'s `pull_request` trigger still carries `branches: [main]`. It does not: the sentence reads "the `[main]` this file carried **until** #87", which is correct. No repair.

---

## A. Statements that are wrong, in documents an agent acts on

Highest priority. Each is a one-to-three-line edit, and each currently sends a reader somewhere wrong.

| #   | Where                                                          | What it says                                                                                                            | What is true                                                                                                                                                                                                                                                                                                                              |
| --- | -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | `README.md:11`                                                 | "the beam's brightness does not vary with how fast it sweeps … Those are the rest of phase 3, and **each** is an issue" | #58 landed velocity weighting. Only #59 remains, so it is one issue, not two                                                                                                                                                                                                                                                              |
| A2  | `CONTRIBUTING.md:68-75`                                        | "REAPER honours `CLAP_PATH`… **Move any installed copy aside first**" plus the command                                  | `AGENTS.md:185` forbids exactly this, and `docs/notes/host-verification.md:46` records `CLAP_PATH` as "measured, works, and **deliberately not used** … not so the route is taken"                                                                                                                                                        |
| A3  | build plan `:431`                                              | `#94 … Open`                                                                                                            | Landed: `build.zig:116,121`, the `test-modes` job at `ci.yml:177`, a done plan, and line 498 of the same file describing it as shipped                                                                                                                                                                                                    |
| A4  | `AGENTS.md:19`                                                 | "The next issue in the plan's order is **#79**"                                                                         | #79 is `Done`, closed as covered by #58. The next is #59                                                                                                                                                                                                                                                                                  |
| A5  | `AGENTS.md:11`                                                 | "Phase 3 …, **four** numbered steps in"                                                                                 | Written at `4a69984` (#57, step 4). #58 landed step 5                                                                                                                                                                                                                                                                                     |
| A6  | `docs/notes/concurrency-and-canaries.md:15`                    | "`Gate` in **`src/clap/gui.zig`**"                                                                                      | `src/clap/gate.zig` since #91, which is _why_ it moved. Line 7 of the same note says so. Same stale pointer at `src/platform/io.zig:6`                                                                                                                                                                                                    |
| A7  | `docs/notes/concurrency-and-canaries.md:15`                    | "**Nothing in the type system stops it**"                                                                               | True of the signal handlers it was copied from (`io.zig:27-28`), false of the constructor. `io.zig:46-49`: "**The type system already refuses the obvious substitution** … a container-level initializer must be comptime-evaluable". The note omits the half `AGENTS.md:32` asserts, so the thin file is more accurate than the deep one |
| A8  | `docs/notes/ci-workflows.md:15`                                | "**Two jobs** are deliberate exceptions" to measured ceilings                                                           | Four are now explicitly unmeasured by their own comments: `python` (`ci.yml:679-683`), `actionlint` (`:761-765`), `markdown` (`markdown.yml:48-56`), `budget` (`:149-151`). The note never mentions `markdown.yml` at all, though its remit is every workflow                                                                             |
| A9  | `build.zig:560-561` and `src/gpu/metal/renderer.zig:3603-3604` | `measure-trace` restates "four constants … two from `src/gpu/iface.zig` and **two from `shaders/scope.metal`**"         | The test at `renderer.zig:3616-3697` pins **twelve**, from `iface.zig` and `palette.zig`, and **none** from MSL. `renderer.zig:3645-3648` says so outright: "#60 moved it there … there is no colour literal left in MSL to compare against". `scripts/measure-trace:46-48` gives a third count, seven                                    |

A9 is the sharpest of the nine: `build.zig` documents a linkage that code four hundred lines away documents as retired, and a reader trusting it would look for a check in the wrong language.

---

## B. Stale figures

`.github/docs.instructions.md:13` governs this section: **an anchored figure and a present-tense figure are allowed to differ, and the repair is a fresh measurement of the present-tense one, never editing the anchored one to match.** Every figure below is present-tense. Every anchored one found during the audit is correct as written and is left alone.

| #   | Figure                            | Where it is present-tense                                                                                                                                                                                                                           | How to settle it                                                                                                                                                                                                                     |
| --- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| B1  | The suite's size                  | build plan `:498` ("**295 named** … and 318"), `src/main.zig:60` ("still run **285** tests"), `docs/notes/concurrency-and-canaries.md:5` ("passes all **144** tests")                                                                               | One `zig build test` run. Correct only these three; leave every "went from X to Y" alone                                                                                                                                             |
| B2  | Judges and `check*` functions     | `docs/notes/smoke-harness.md:13` ("**fifteen** judges the **thirteen** `check*` functions"), `src/main.zig:118` ("the **thirteen** hardest claims"), `src/gpu/verdict.zig:412,434` ("**fifteen** public functions", "all fifteen judge signatures") | #58 added `velocityPerLength`, `velocityTotal`, `velocityInvariance` and `periodRatio`, and `checkVelocityWeighting` at `smoke.zig:1107`. Re-count both                                                                              |
| B3  | Files reaching the canary helpers | `docs/notes/concurrency-and-canaries.md:5` ("**five** files reach them"), `src/main.zig:100-103` (says **five**, three times)                                                                                                                       | `rg 'canary\.' src/` excluding `canary.zig` reaches nine files                                                                                                                                                                       |
| B4  | `shfmt -f`'s file count           | `docs/notes/linters.md:15` and `.github/workflows/ci.yml:658`, both "**twelve** files"                                                                                                                                                              | Thirteen since `scripts/check-doc-budget` landed with #117. Two live copies of one figure                                                                                                                                            |
| B5  | Markdown file count               | `docs/notes/linters.md:15` and `ruff.toml:28`, both "all **53** `.md` files"                                                                                                                                                                        | 99. The conclusion each draws is still right; only the count moved                                                                                                                                                                   |
| B6  | macOS jobs                        | `docs/notes/ci-workflows.md:5`, "the **7 real macOS jobs**"                                                                                                                                                                                         | Eight since `test-modes`. This is also the note's only _unanchored_ job count, which is the one `AGENTS.md:195` actually forbids — so drop it rather than correcting it                                                              |
| B7  | The shader's size                 | `src/gpu/metal/shader.zig:60,70,75` and `renderer.zig:2684`, "around twenty-two kilobytes" / "22,050"                                                                                                                                               | `shaders/scope.metal` is 29,121 bytes. The test still passes, but the paragraph calling this "**the last move of the factor that is honest**" budgets ten kilobytes of headroom and 3.6 KB remain. Re-measure and restate the margin |
| B8  | Counts inside `ci.yml`            | `:727` ("this file is **46 KB**"), `:764` and `:822` ("**four** workflow files")                                                                                                                                                                    | 62,917 bytes and five files. `:822` is the sentence a reader uses to confirm `markdown.yml` is linted at all. Per `AGENTS.md:195`, prefer deleting the counts to correcting them                                                     |
| B9  | `src/clap/gui.zig:1076`           | "invisible to all **42** tests beside it"                                                                                                                                                                                                           | `gui.zig` carries 47 test blocks                                                                                                                                                                                                     |
| B10 | `AGENTS.md:40`                    | "**five artifacts** from one core" followed by six items                                                                                                                                                                                            | Five is right (`fosforo_impl`, `fosforo`, `fosforo-smoke`, and the two race harnesses); the `.clap` is the dynamic library assembled, not a sixth. Reword the enumeration                                                            |
| B11 | build plan `:76`                  | ADR 0016 as "Verify **the ring's** release/acquire pairing"                                                                                                                                                                                         | `docs/adr/README.md:26` says "the ring's **and the gate's**". The row predates #91                                                                                                                                                   |

**Discipline for this section**, from `AGENTS.md:193`: for every figure corrected, `rg` the old value across the repository before committing and report every live occurrence. B1, B2, B3, B4 and B5 each already have two or three live copies, which is what that rule exists to catch.

---

## C. Citations and listings that no longer resolve

All in living documents. Nothing in `docs/plans/done/` is touched — a done plan's pre-change citations are correct precisely because they no longer resolve.

| #   | Citation                                                        | Resolves to                             | Should be                                                                                                                                                                                                                                                                                           |
| --- | --------------------------------------------------------------- | --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1  | `docs/notes/reading-diagnostics.md:27` → `src/clap/gui.zig:629` | `defer self.resizing = false;`          | `Editor.report` at `gui.zig:827`, emitting at `:837`                                                                                                                                                                                                                                                |
| C2  | `docs/notes/shader-plumbing.md:13` → `src/clap/log.zig:109`     | a doc-comment line                      | `log.zig:113`, the `if (builtin.mode != .Debug or builtin.is_test) return;` idiom                                                                                                                                                                                                                   |
| C3  | `docs/notes/concurrency-and-canaries.md:9` → `gui.zig:167-173`  | the tail of `post`'s doc comment        | `packed struct(u64)` at `gui.zig:143`, the `u64` slot at `:136`                                                                                                                                                                                                                                     |
| C4  | build plan `:110-137`, "Source layout — what exists **today**"  | omits seven files that exist            | Add `build_info.zig`, `canary.zig`, `clap/gate.zig`, `gpu/palette.zig`, `gpu/verdict.zig`, `gpu/metal/reload.zig`, `gpu/metal/shader.zig`. It lists `gate_race.zig` but not the `Gate` it races. `AGENTS.md:63-88` has the correct list — consider pointing at it rather than keeping a second copy |
| C5  | `AGENTS.md:51-62`, the `scripts/` block                         | eleven of twelve scripts                | `scripts/check-doc-budget` is missing, and it is the script `AGENTS.md:222` depends on by name. `.editorconfig:48` has the complete list                                                                                                                                                            |
| C6  | `.github/workflows/ci.yml:743,745`                              | comments naming the `ring-race` **job** | Renamed to `race` by #91 (ADR 0016's amendment records it). The only live `ring-race` in the file is the _step_ at `:570`                                                                                                                                                                           |
| C7  | `src/platform/io.zig:6-7`                                       | "`Gate` in `clap/gui.zig`"              | `clap/gate.zig`. Same as A6; fix both in one commit so the grep comes back clean                                                                                                                                                                                                                    |

**Not in scope:** the todo verification-gaps plan's own decayed citations. Section G retires that whole set at a stroke.

---

## D. Constants restated where nothing links them

This is the section with a latent release defect in it.

### D1. The version lives in five places and three are checked — **the one to do first**

| Place                                                            | Value   | Checked by `build-installer`? |
| ---------------------------------------------------------------- | ------- | ----------------------------- |
| `build.zig.zon:3` `.version`                                     | `0.0.0` | yes                           |
| `macos/Info.plist:20` `CFBundleShortVersionString`               | `0.0.0` | yes                           |
| `macos/Info.plist:22` `CFBundleVersion`                          | `0.0.0` | yes                           |
| **`cmake/CMakeLists.txt:23` `project(fosforo VERSION 0.0.0 …)`** | `0.0.0` | **no**                        |
| `package.json:3`                                                 | `0.0.0` | no (private, inert)           |

`cmake/CMakeLists.txt:143` feeds `${PROJECT_VERSION}` into `BUNDLE_VERSION`, which clap-wrapper writes into the shipped `Fosforo.component`'s own `Info.plist`. Bump the first three to `0.1.0` for the release and forget CMake: `resolve_version` (`scripts/build-installer:103-127`) reports agreement, `pkgbuild --version 0.1.0` succeeds, and the Audio Unit inside the package says `0.0.0`. Nothing anywhere notices.

Compounding it, `packaging/distribution.xml:6-9` understates the count in a way that hides the gap: "Hardcoding it here would make this a **fourth** place the version lives … and the script already refuses to package a disagreement among **those three**." It is already the fifth, and CMake is not in the enumeration.

**Repair:** extend `resolve_version` to read the CMake project version as a fourth input, restate its diagnostic over four values, and correct the `distribution.xml` comment. This is the one change in this plan that alters behaviour, and it is a refusal being widened rather than a check being added to new code.

### D2. Lists that under-count their own sites

| Constant                 | Actual sites                                                                                            | Documents claiming fewer                                                                                                                                                                                                                                                                                                    |
| ------------------------ | ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deployment target `11.0` | four: `build.zig:25`, `cmake/CMakeLists.txt:39`, `macos/Info.plist:26`, `packaging/distribution.xml:31` | `docs/notes/build-system.md:15` ("three"), `.github/cmake.instructions.md:16` (names two), `.github/zig.instructions.md:21` ("three places"), `src/platform/displaylink.zig:16` (says three, lists four, one of which is an ADR). Only `packaging/distribution.xml:27-28` is right, and it says "**Keep the four in step**" |
| Display name `Fósforo`   | eight sites in five files, including `packaging/distribution.xml:19` `<title>`                          | `docs/notes/build-system.md:23`: "**The display name lives in four places** … Change one, change all four." The installer's own title is not among them                                                                                                                                                                     |
| The description string   | `src/clap/plugin.zig:60` and `cmake/set-au-display-name:66`, verbatim                                   | listed nowhere                                                                                                                                                                                                                                                                                                              |

Raising the deployment floor from `build-system.md` as written leaves the installer either refusing on nothing or accepting a machine the binaries will not run on.

### D3. Grep-based CI assertions that a rename makes vacuous

- `ci.yml:1075` greps the literal `FOSFORO_SHADER_PATH`; the source of truth is `src/gpu/metal/shader.zig:56` `pub const path_env`. Rename the value and the assertion "no shipped binary carries the shader-reload path" passes forever against a needle that can no longer appear. `ci.yml:1071` has the same shape for `shaders/scope.metal`, owned by `build.zig:16`.
- `ci.yml:1067` is a **third** live spelling of `src/build_info.zig:48`'s `marker_prefix`, whose design note at `:43-47` ("**Changing this changes an interface**") assumes two. The other restatement, `scripts/read-provenance:72`, _is_ tied by the test at `build_info.zig:211-223`.

The positive control at `:1067` protects the binary being readable, not the needle still being right. Cheapest repair: state the coupling in a comment beside each grep naming the Zig declaration, and note in `docs/notes/ci-workflows.md` that these three are unlinked restatements. A test that reads `ci.yml` the way `build_info.zig:211` reads `read-provenance` is the stronger fix and is worth filing rather than doing here.

### D4. `package.json:6` declares `MPL-2.0`

`LICENSE:1`, `README.md:71` and `macos/Info.plist:28` all say MIT. The file is `"private": true` so nothing publishes it, but it is a tracked file making a false statement about the repository's licence and it is the only one that disagrees.

---

## E. Script and CI hygiene

| #      | Finding                                                                                                                                                                                                                                                                                                                                                | Why it matters                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E1     | `scripts/assert-adhoc-signature` and `assert-distributable-signature` are ~60 lines of shared copy-paste with **four uncommented asymmetries**: `-d` vs `-e` (`:160` / `:158`), a `codesign --verify --strict` precheck present in only one (`:87`), a literal `'^Authority='` grep vs a `REQUIRED_AUTHORITY` constant, and a dropped `Returns:` block | This repository comments deliberate asymmetries everywhere else, so four uncommented ones read as drift. `-d` vs `-e` is the live one: both callers (`build-release-bundles:144`, `build-installer:252`) pass directories, so `-e` silently accepts a plain file where its inverse refuses                                                                                                                                                                                                                                |
| E2     | `scripts/install-plugins` is the only one of thirteen scripts with **no `TRACE` block**, and it computes the repo root twice in two spellings (`:67-68` `SCRIPT_DIR`, `:405` a second `cd … pwd`)                                                                                                                                                      | It is also the script that runs `rm -rf` inside the user's plug-in folder, so it is the one where `TRACE=1` would matter most                                                                                                                                                                                                                                                                                                                                                                                             |
| E3     | `ci.yml:621-625` and `:806-810` are a byte-identical five-line shellcheck install block                                                                                                                                                                                                                                                                | `ci.yml:98-115` hoisted the _version pair_ to workflow `env` on the stated grounds that "Duplicating one would let the two copies drift, **and a drifted copy still passes**". The install steps were not given the same treatment — the repo's own principle applied halfway                                                                                                                                                                                                                                             |
| E4     | `scripts/assert-adhoc-signature:20` points at "the release section of `AGENTS.md`"                                                                                                                                                                                                                                                                     | `AGENTS.md`'s "Releasing" never names `assert-distributable-signature`; it appears only in the Structure block at `:59`. The pointer resolves to nothing                                                                                                                                                                                                                                                                                                                                                                  |
| ~~E5~~ | ~~`zig-pkg/` is ignored in five config files for a directory nothing produces~~ **WRONG, and instructive**                                                                                                                                                                                                                                             | A plain `zig build` creates `zig-pkg/` and unpacks CLAP and `zig-objc` into it, verified in a scratch copy. The audit's evidence was that `rg` found no reference to the path — and `rg` found none **because `.gitignore` was hiding the directory from `rg`**. Removing the five entries made Prettier walk vendored CLAP Markdown, `markdownlint` report MD041 on upstream READMEs, and `typos` report twenty-odd findings in third-party headers. Reverted, and recorded in `docs/notes/linters.md` as its own bullet |
| E6     | `gitleaks.yml:17` and `trufflehog.yml:17` both name their job `scan`                                                                                                                                                                                                                                                                                   | `markdown.yml:44-48` states the rule and its evidence: "two workflows both using `check` produce two indistinguishable rows in a pull request's rollup … Observed on #115 before this rename." Either rename these two or give the rule a stated scope                                                                                                                                                                                                                                                                    |
| E7     | `CONTRIBUTING.md:106` says "**Three checks** exist that `zig build test` deliberately does not run" and lists five (`smoke`, `smoke-trace`, `smoke-leaks`, `ring-race`, `gate-race`); `:44-56` and `:202` never mention `test-safe` or `test-release`; neither `CONTRIBUTING.md:197-207` nor `.github/PULL_REQUEST_TEMPLATE.md` mentions `actionlint`  | A contributor following CONTRIBUTING runs one of the three test modes CI requires, and skips a required job entirely                                                                                                                                                                                                                                                                                                                                                                                                      |

E6 is cheap; E1 and E2 are the two worth doing carefully, since both touch scripts that sign or delete things. E5 was the one finding in three audits that was simply wrong, and it is left struck through rather than deleted because the way it was wrong is worth more than the finding would have been.

---

## F. `AGENTS.md`: trim, then correct

`scripts/check-doc-budget` reports **26,942** characters against a 27,000 warning and a 30,000 refusal. **58 characters of headroom**, so every correction in this plan that touches the file must be net-negative or it trips the advisory on the next push.

**Trim first** (the two clearest duplications, both prescribed by `AGENTS.md:228`'s own rule that a measurement belongs in a note):

1. `AGENTS.md:17`'s velocity-weighting paragraph restates `docs/notes/trace-and-phosphor-physics.md:25` nearly clause-for-clause, down to "energy per unit length falls as `1 / len` above the beam's own width and levels off below it". Keep the one-line claim and the pointer; the derivation is already in the note.
2. `AGENTS.md:222-231`'s budget rationale is a third copy of `scripts/check-doc-budget:5-26` — the 40,000 formula, the 139 commits, the 166,639, the "raising the budget is not the repair" argument. Keep the rule and the two thresholds; the reasoning is in the script's own header and in the #117 done plan.

**Then land inside the freed space:** A4, A5, C5, B10, and:

- `AGENTS.md:34` asserts "**Every** ordering-critical declaration is canaried" and then enumerates five mechanisms. There are fifteen canary tests across six files — `gui.zig:1106` alone covers five more atomics (`presented`, `window`, `uploaded`, `torn`, `meter_reset`), plus `io.zig:129`, three in `renderer.zig` and three in `gate_race.zig`. Every named item was verified present and matching; the list is not wrong, it is a partial enumeration reading as a complete one. Reword so the sentence claims the convention and points at `docs/notes/concurrency-and-canaries.md` for the inventory.
- Same bullet: it is the only Non-negotiable citing no ADR, against `AGENTS.md:23`'s promise that these are "settled decisions recorded in `docs/adr/`". ADR 0016 covers the two TSan harnesses; the source-canary _convention_ it asserts is covered by its #91 amendment. Cite ADR 0016 there.

**Also worth a decision, not resolved here:** `AGENTS.md:203-218` and `docs/notes/README.md:11-27` are two hand-maintained indexes of the same fourteen notes, already differing in wording per row, with nothing tying them together — the opposite of `src/main.zig:198-204`, which ties two lists with a test for exactly this reason. Leaving both is defensible (they answer different questions); a fifteenth note added to one and not the other fails nothing.

---

## G. Move the verification-gaps plan to `done/`

`docs/plans/todo/2026-09-04-close-the-verification-gaps-in-the-test-suite.md` is 10 of 11 complete and has decayed accordingly: its Summary table marks only #93 and #94 done while eight more have landed, line 48 says "**Nine** of the eleven have landed" and lists nine while dropping #90 (which landed), line 54 then says "The one remaining is #98" — nine plus one is ten, not eleven — and roughly half its `path:line` citations no longer resolve, including `gui.zig:916-941` for a `Gate` that now lives in another file.

Because it sits in `todo/`, every one of those is a defect. In `done/` they become the format working correctly.

**Nothing is lost by moving it.** Issue #98 already carries the full seam decision — all three candidates, the recommendation, the ADR 0013 obligation, and a three-item acceptance checklist — verified by reading the issue.

Steps:

1. `git mv` the file to `docs/plans/done/`.
2. Update the three relative links that point at it: build plan `:264`, `:420`, and the "Documents this program updates" region near `:486`.
3. Update the trailing `plan:` path in issue #98's body, which will otherwise point at `todo/`.
4. Leave the file's contents untouched, including every stale citation. That is the whole point of the move.

---

## H. Issues to file, not fixed on this branch

Filed rather than fixed on the decision recorded above and on phase 3's rule that an issue's code and its verification land together. The first two are genuine defects.

| Title                                                                               | Substance                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fix: velocityInvariance passes a run that drew nothing`                            | `src/gpu/verdict.zig:834-847` computes `spread = high / low` with `low` seeded at `floatMax` and `high` at `0`. An all-dark `totals` gives `0/0 = NaN`, and `NaN > 1.05` is **false**, so nothing-drawn reports the invariance as holding. This is verbatim the hole `verdict.zig:25-30` says the file closed twice: `decay:1100` and `realTimeDecay:1179` both guard with `if (!(first > 0)) return Fault.TraceNotDrawn;` and this one does not. Currently masked only because `velocityTotal` refuses a dark readback first — the positional protection `verdict.zig:401-406` explicitly rejects. Secondary: `high` seeded at `0` rather than `-floatMax`. Sibling of `3a2baaa`, which swept the geometry helpers and not this |
| `test: cover the three velocity judges and DepositNotVelocityWeighted`              | `velocityPerLength:780`, `velocityTotal:811` and `velocityInvariance:834` are referenced only from `src/smoke.zig`, so they run only under the step that needs a GPU. `Fault.DepositNotVelocityWeighted` is asserted by zero tests — one of two members of a 32-member enum that no test reaches. This is the exact gap `main.zig:114-121` says naming `verdict.zig` closed, and `verdict.zig:1236-1238` claims "every one of them expressible as a synthetic readback is a test below". All three are expressible; the existing `Canvas`/`beamRow` helpers suffice. Pair it with the guard above so the plant proves the test discriminates                                                                                     |
| `fix: measure-trace's derived rows disagree with measure.zig by half a pixel`       | `measure.centreRow` (`measure.zig:389-391`) is `height / 2 - 0.5`; `scripts/measure-trace:896` prints `height / 2`. `rail_row` at `:891` carries the `- 0.5` and agrees exactly, so this is #57's half-pixel correction applied to two of three derived rows. It is also computational, not only cosmetic: the period band at `:981` uses `height / 2` where `measure.zig:469-478` uses `centreRow`, and compares with `<` where the Zig side uses `<=`. Cross-reference #126, which owns the same file's threshold constant but not this                                                                                                                                                                                        |
| `fix: passThrough trusts out.channel_count where every other host input is refused` | `src/clap/plugin.zig:585-588` indexes `out.data32[channel]` up to the host's `channel_count` with nothing bounding it, and the second loop spins that many times on the audio thread. Every other host input on that path is explicitly refused with a stated reason — `frames_count` at `:515`, `sample_rate` at `:324`, `max_frames_count` at `:325-326` — each noting that an assertion is compiled out of the build where a misbehaving host does damage. `bit()` at `:633` already acknowledges "CLAP puts no ceiling on `channel_count`" for the mask. No test can reach it: `TestBuses` is two channels by construction                                                                                                   |

**Secondary candidates**, worth filing only if the user wants them:

- `accumulation_pixel_format` (`renderer.zig:209`) and `energy_bytes_per_pixel` (`:2947`) are an unchecked coupling; `drawable_pixel_format` has exactly such an assertion at `:3880`. Changing the accumulation to `R16Float`, which `scope.metal:490-494` contemplates, skews the readback rather than failing.
- `src/ring_race.zig` has none of the three canaries `gate_race.zig` carries, despite documenting both hazards (the one-shot warm-up at `:269-283`, the `Weakened` replica at `:325-351`) as having been found by planting. `main.zig:137-141` argues why they matter.
- The palette texture's live count is incremented at the call site (`renderer.zig:1324-1325`) rather than inside its builder, unlike `buildAccumulation:2577` and `buildWindows:2516`.
- A test that reads `ci.yml`'s three grep needles the way `build_info.zig:211-223` reads `read-provenance` (D3).

---

## Explicitly not in scope

Recorded so each is not re-raised on review.

- **Anything in `docs/plans/done/`.** Pre-change citations, proposed identifiers that differ from what shipped, and stale figures are all the format working. `AGENTS.md:194` and `.github/docs.instructions.md:10-14` are absolute about it. The audit found **no** wrongful post-completion rewrite; every later edit was a same-issue follow-up, a tree-wide Prettier pass, or an explicitly-argued annotation blockquote.
- **Editing any ADR's standing text.** ADRs are superseded, not edited. `docs/adr/0013` at 73 KB with twelve amendments, several duplicated by the notes that were meant to absorb them, is an observation and not a defect: the ADR records decisions and the note records behaviour, and both are allowed to state the same measurement.
- **Reconciling an anchored figure to a present-tense one, in either direction.** `.github/docs.instructions.md:13`.
- **The `docs/notes/ci-workflows.md` `branches: [main]` claim.** Checked and correct; see the Method note.
- **Raising the doc budget.** `AGENTS.md:233`: "Raising the budget is not the repair."

One question the audit raised and did not settle, left for the user: `.prettierignore:8-11` excludes `docs/design/scope-plugin-handoff.md` because "Reformatting it would edit a historical record", while `docs/plans/done/**` is described identically by `AGENTS.md:194` and is **not** excluded — `npm run format` duly reformatted forty-odd done plans in `668a029`, which is the thing `AGENTS.md:191` forbids `markdownlint-cli2 --fix` for. Either the done plans belong on both ignore lists, or the design doc's stated reason does not hold. Not touched here.

---

## Commit sequencing

Small conventional commits at each boundary, per the repository's habit. Roughly:

1. `docs: correct four statements a reader would act on and be wrong` — A1, A2, A4, A8
2. `docs: point three citations at the code they name` — A6, C1, C2, C3, C7 (one commit, because A6 and C7 are the same stale pointer in two languages and the grep must come back clean)
3. `docs: mark #94 done and restore the source layout` — A3, C4, B11
4. `docs: re-measure the figures later work moved` — B1 through B9, each grepped repo-wide first
5. `docs: say what measure-trace actually restates` — A9
6. `fix: check the CMake project version before packaging` — D1, the one behaviour change
7. `docs: name every site each restated constant reaches` — D2, D3's comments, D4
8. `chore: close the four gaps between the two signature scripts` — E1
9. `chore: give install-plugins the trace block and one root` — E2
10. `ci: stop the shellcheck install drifting between two jobs` — E3, C6, B8
11. `chore: retire the zig-pkg ignores and name the scan jobs apart` — E5, E6
12. `docs: bring CONTRIBUTING up to what CI requires` — E7, E4
13. `docs: trim AGENTS.md into its notes, then correct it` — F, last so the budget is measured against the finished tree
14. `docs: move the verification-gaps plan to done` — G

---

## Verification

**Mechanical, all currently green — every one must stay green:**

```bash
zig fmt --check build.zig src/
zig build test && zig build test-safe && zig build test-release
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
git ls-files -z | xargs -0 shfmt -f | xargs shellcheck
actionlint
typos
ruff format --check . && ruff check .
npm ci && npm run format && npm run lint:md   # format BEFORE lint; never markdownlint-cli2 --fix
scripts/check-doc-budget                      # must come back under 27,000, not merely under 30,000
```

`node_modules/` is absent in this worktree, so `npm ci` is required before the Markdown pair means anything.

**Proving the documentation changes moved nothing:**

- `zig build smoke-gpu` and `zig build smoke-trace` before and after, transcripts compared below the provenance line. Both are in the free lane: a device, no window, no host. A doc-only branch that moves a smoke figure has changed something it did not mean to.

**Proving D1 is a real refusal and not a vacuous one** — this is the only behaviour change, so it gets a plant:

1. `scripts/build-installer --unsigned` against the tree as it stands: passes, four values agreeing.
2. Edit `cmake/CMakeLists.txt:23` to `VERSION 0.0.1`, re-run: **must refuse**, naming CMake in the diagnostic.
3. Revert, re-run: passes.

Without step 2 the widened check is indistinguishable from one that reads the new value and ignores it, which is the failure `docs/plans/done/2026-09-05-close-the-eleven-cheap-assertions.md` records as "a plant that does not compile is not a passing plant".

**Proving E1's `-d`/`-e` repair:** pass a plain file to `scripts/assert-distributable-signature` and confirm it now refuses, matching its inverse.

**Per-figure discipline (B):** for each corrected value, `rg '<old value>'` across the tree and record every live occurrence in the commit message. Occurrences under `docs/plans/done/` are not live.

**Not run here:** anything needing a host, a window server or a certificate. Nothing in this plan touches the render path, the audio path, the editor's lifecycle or the signing identity, so REAPER, Logic and `assert-distributable-signature`'s positive direction are all unnecessary. The four issues in section H are where host verification will be needed.
