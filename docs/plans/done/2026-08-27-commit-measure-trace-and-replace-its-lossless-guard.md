# Commit `measure-trace` here, and replace its lossless guard

Issue: [#64](https://github.com/cboone/fosforo/issues/64). Branch: `chore/scripts`.

> **Pointer added by [#67](https://github.com/cboone/fosforo/issues/67):** `scripts/make-test-tones`, named below, no longer exists here. The generator moved to `tools/test-signals/maketones.py` in [cboone/audio-tools](https://github.com/cboone/audio-tools), and `AGENTS.md` carries the invocation that reproduces this project's signal set. `measure-trace` stayed, for the reasons this document gives; the half that left is the half that was general.

## Context

`measure-trace` is the tool every number in [#38](https://github.com/cboone/fosforo/issues/38)'s verification came out of: the level sweep's peak rows, the plateau widths, the period counts, the implied sample values. Those numbers are quoted in `AGENTS.md`, in ADR 0017's reasoning, and in the phase 2 exit criteria, and they are quoted as measurements rather than as claims.

The tool is in no repository at all. It lives at `~/Music/fosforo-test-tones/measure-trace`, beside the WAVs `scripts/make-test-tones` renders, and `git log --all -S measure-trace` is empty in this repository and in `audio-tools` both. One copy, on one machine. If it goes, every number it produced becomes an unreproducible assertion.

Two things are wrong with it as it stands, and the second one only became wrong when [#55](https://github.com/cboone/fosforo/issues/55) landed:

- It restates four of this project's constants with nothing linking them, so a constant that moves leaves the tool reporting confident numbers against the old mapping.
- Its lossless guard refuses any capture holding more than 32 distinct green levels, on the premise that "a lossless capture has 2". That was true of a trace with no persistence. A decaying trail occupies dozens of green levels by construction, so a perfectly good PNG is now refused with a message telling the author to recapture it, and the only way through is `--allow-lossy`, whose name then describes the wrong thing.

This issue is the one the phase 3 working order places immediately after #55, for exactly the reason above: the guard's acceptance test is a capture of a trace that actually fades, and that did not exist until #55 merged. It has.

Where it goes is settled in the issue and not reopened here: **this repository, at `scripts/measure-trace`**, because the tool is this project's display contract restated in Python rather than general analysis, and because the fix for its worst property, a test that reads the script and checks its constants, is only available in-repo.

## Decisions taken

Three were open when this plan was written. All three are now closed.

| Question                    | Choice                                                                                        | Why                                                                                                                                                            |
| --------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Does it acquire a linter?   | **Yes: `ruff`, pinned by version and SHA256, in a new `python` CI job**                       | The only file here producing load-bearing numbers must not also be the only unchecked one. `shfmt -f` provably skips it, so nothing existing would ever see it |
| What replaces `shades > 2`? | **A colour-ray test**: every pixel is `background + a * beam`, so red and blue follow green   | Structural rather than statistical. Decay scales all three channels equally, so persistence passes by construction; chroma subsampling and ringing fail        |
| How far does the tie reach? | **All four constants**, two against `src/gpu/iface.zig` and two against `shaders/scope.metal` | The crop and the new guard both depend on the two colour literals, so all four are hand-kept copies                                                            |

## The guard, in detail

The renderer writes, for every pixel of the drawable:

```text
resolve = float3(0.02, 0.02, 0.03) + energy
energy  = c * float3(0.30, 1.0, 0.45)      c >= 0
```

Every deposit is the same colour and decay multiplies the whole vector, so accumulated energy is always a scalar multiple of the beam colour. The drawable is `BGRA8Unorm` and not sRGB, so the 8-bit values are linear in that expression. Given green, red and blue are therefore predicted:

```text
a      = (G - 0.02 * 255) / 255
R_pred = 0.02 * 255 + 0.30 * 255 * a
B_pred = 0.03 * 255 + 0.45 * 255 * a
```

Green saturates first, at `c = 0.98`, so a pixel at or near `G = 255` carries no usable `c` and is excluded. Everything below that must lie on the ray within rounding.

This is what a codec breaks and persistence does not. Chroma subsampling puts green into neighbouring pixels without their red and blue partners, and ringing puts red and blue where there is no green; both leave the ray. A resampled capture, from a scaled display mode, breaks it the same way, which the old guard could not see at all.

Three constants are provisional in the first pass and get their final values from the measurement in the verification section below:

| Constant        | Provisional | Meaning                                                                     |
| --------------- | ----------- | --------------------------------------------------------------------------- |
| `RAY_TOLERANCE` | 2           | 8-bit levels red or blue may differ from their prediction                   |
| `MAX_OFF_RAY`   | 0.005       | Fraction of unsaturated drawable pixels allowed off the ray before refusing |
| `SATURATED`     | 250         | Green level at or above which a pixel is excluded as clipped                |

Three further changes travel with it:

- **`--allow-lossy` becomes `--measure-anyway`.** The old name described the wrong thing the moment the guard stopped being about codecs alone.
- **The distinct-green-level count keeps being printed, as information rather than as a gate.** It is the tell for whether a trail is present, and it is the number the old guard was built on, so keeping it visible makes the change legible to anyone holding #38's tables.
- **A persistence note.** When more than two green levels are present, print one line saying the peak row is the topmost lit pixel over the persistence window rather than this frame's sample. That is the measurement's meaning changing under #55, which the issue puts out of scope as a fix and which the tool should still say out loud. Deliberately carries no frame count, because computing one would restate `decay_per_frame` as a fifth constant.

The refusal message stops saying "lossy" and says what is actually true:

```text
7.4% of the drawable's unsaturated pixels are colours this shader cannot produce.
It writes background + a * (0.30, 1.0, 0.45), so red and blue follow green exactly.
A resampled or recompressed capture breaks that and moves every number below.
Recapture with:  screencapture -o -x -t png -W shot.png
Pass --measure-anyway to measure it regardless, knowing the peak will read high.
```

## The constants test

`scripts/measure-trace` grows two constants and loses two hardcodings:

```python
FULL_SCALE = 0.9                  # iface.trace_full_scale
RAIL = 0.98                       # iface.trace_rail
BACKGROUND = (0.02, 0.02, 0.03)   # resolve_fragment's literal, before quantisation
BEAM = (0.30, 1.0, 0.45)          # trace_fragment's literal
```

`BACKGROUND` is stored as the shader's floats rather than as `RGB(5, 5, 8)`, which is what makes the test a literal-to-literal comparison with no conversion in it, and what lets `find_drawable`'s exact-match window and the ray prediction both derive their centres from one source. The empirical parts of the crop, the tolerance either side and the 2-to-4 blue lead, stay as tuned constants with their existing comment: they describe what a capture does, not what the shader writes.

The test lives in `src/gpu/metal/renderer.zig`, beside `bindingIndexAfter` and the two layout tests, because that file already imports `iface` for both scalars and already embeds `shaders/scope.metal` for the shader literals. `src/gpu/iface.zig` gets a pointer at `trace_full_scale` and `trace_rail` saying they are restated in the script and naming where the test is.

Two comptime helpers, on `bindingIndexAfter`'s pattern of anchoring on the declaration rather than on the value:

- `scalarAfter(source, needle) ?f64`, for `FULL_SCALE = ` and `RAIL = `.
- `scalarsAfter(source, needle, n) ?[n]f64`, for the first parenthesised list after a needle. One helper covers both a Python tuple and an MSL constructor, which is a small piece of luck worth taking.

The MSL anchors must be the definitions, not the names: `trace_fragment` and `resolve_fragment` both appear in the file's header comment, and the first `float4(` after that comment is in `fullscreen_vertex`. Anchor on `"fragment float4 trace_fragment"` and `"fragment float4 resolve_fragment"`, which appear once each.

`float4(0.30, 1.0, 0.45, 1.0)` is parsed as four numbers, the first three compared against `BEAM` and the fourth asserted to be 1.0.

A matching negative test goes beside it, on the precedent of "the binding reader finds nothing rather than guessing": both helpers must return `null` for a needle that is absent, so a declaration that moved fails rather than reading as a pass.

## What lands, in commit order

Five commits, then the host measurement, then a sixth for what the measurement changed.

### 1. `chore: commit measure-trace, the tool #38's numbers came out of (#64)`

- `scripts/measure-trace`, byte-for-byte as it exists at `~/Music/fosforo-test-tones/measure-trace`, mode 755. Verbatim deliberately: it makes provenance exact and makes every later commit a readable diff against the thing that produced the published numbers.
- `.editorconfig`: a `[measure-trace]` section with `indent_style = space` and `indent_size = 4`. It cannot join the shell section, whose four keys are `shfmt` directives. The section carries a comment that `ruff`, unlike `shfmt`, does **not** read `.editorconfig`, so the two are kept in step by hand.

### 2. `ci: lint the first Python here with a pinned ruff (#64)`

- `ruff.toml` at the repository root: `line-length = 100`, `extend-include = ["measure-trace"]`, and `extend-select = ["I"]` under `[lint]`. `extend-include` is the load-bearing line: ruff discovers Python by extension and this file has none, so without it a walk of the tree finds nothing and the job passes vacuously.
- `.github/workflows/ci.yml`: a `python` job after `shell`, on `ubuntu-latest` with `timeout-minutes: 3`, mirroring `shell` and `typos` in shape. `RUFF_VERSION` and `RUFF_SHA256` as job `env`, the binary downloaded to a file and summed before it is unpacked, a "Report tool version" step so a sum bumped without its version fails legibly, then `ruff format --check .` and `ruff check .`. No file arguments, matching `typos`: ruff respects `.gitignore`, which already covers `build/`, `zig-out/` and `zig-pkg/`.
- Whatever `ruff format` does to the script, in the same commit as the tool that did it.

### 3. `fix: refuse a capture by colour rather than by shade count (#64)`

The guard replacement above, the flag rename, the persistence note, and the `BACKGROUND` and `BEAM` constants with `find_drawable` deriving its centres from the first.

### 4. `test: tie measure-trace's constants to the seam and the shader (#64)`

- `build.zig`: `addTestStep` builds the module, adds `mod.addAnonymousImport("measure-trace", ...)` to it, and passes it to `addTest`. **On the test module only, not in `Core.module`,** so no shipping artifact can carry a Python script's bytes and the claim is structural rather than something to measure afterwards.
- `src/gpu/metal/renderer.zig`: the two helpers, the four-constant test, and the negative test. The `@embedFile` goes inside the test body rather than at file scope, which is what guarantees a plain `zig build` never analyses it.
- `src/gpu/iface.zig`: a sentence at each of `trace_full_scale` and `trace_rail` naming the script and the test.

### 5. `docs: record measure-trace in AGENTS.md (#64)`

- Structure tree: `measure-trace` and `make-test-tones` both. The second is already in the repository and already missing from that tree, and the two are halves of one procedure.
- Development block: the `ruff` invocations beside the `shfmt`, `shellcheck` and `typos` ones.
- A new gotcha bullet immediately after "Every automated check here is blind to whether the picture is bright enough to look at", which is the bullet this tool partially answers. It records: where the tool is and what it measures; that it cannot measure any other oscilloscope, because it is the display contract in Python; that four constants are restated and which test ties them; that the peak row is the trail's envelope under persistence rather than this frame's sample; that it is the only Python here and `ruff` is what lints it; and that `ruff` does not read `.editorconfig`.

## Verification

### Local, and each with its positive control

The controls are the point rather than ceremony: three of the four checks here assert an absence, and this repository has twice shipped an instrument that was never running.

| Check                                                 | Control                                                                                                         |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `zig build test`, 160 tests plus the new ones         | Change `FULL_SCALE` to `0.8` in the script and confirm the test fails, then revert                              |
| `zig build`                                           | Succeeds with the script committed, proving the test-only `@embedFile` is never analysed                        |
| `strings zig-out/Fosforo.clap/Contents/MacOS/Fosforo` | No `FULL_SCALE` and no `measure-trace` prose in the binary                                                      |
| `ruff check .` and `ruff format --check .`            | Plant an unused import and confirm both the local run and the CI job go red; a vacuous pass is the failure mode |
| `git ls-files -z \| xargs -0 shfmt -f`                | Still does not select `scripts/measure-trace`; already measured, re-assert after the reformat                   |
| `typos`                                               | Clean; already measured against the current text                                                                |
| `zig fmt --check build.zig src/`                      | Clean                                                                                                           |

### In a host, which is the only place the guard can be judged

Exclusive on `~/Library/Audio/Plug-Ins` and a host, per the phase 3 working order. Nothing else runs against that path while this does.

1. `zig build install-plugins`, and read **both** hash pairs it prints. A result from an install this branch did not make describes some other build.
1. REAPER from a terminal, `~/Music/fosforo-test-tones/sine-100hz-0.5.wav` on a loop, editor open, meter reading a rate near the refresh rate.
1. `screencapture -o -x -t png -W shot.png`, clicking the plugin window.
1. `scripts/measure-trace shot.png` **must succeed**. This is the case that failed before this branch, and it is the whole acceptance test for the change: a lossless capture of a fading trace measured without a flag.
1. `scripts/measure-trace --explain shot.png` for the deviation table. **This is the measurement everything below is read off**, and the number that matters most is the max: on synthetic captures it is 0.71 levels, which is pure quantisation rounding and the shape expected if the capture path is identity.
1. `sips -s format jpeg -s formatOptions 60 shot.png --out shot.jpg`, then `scripts/measure-trace shot.jpg` **must refuse**, naming the off-ray fraction. This is the guard's positive control, and without it the refusal path is untested. Quality 60 rather than 40: at 40 the background stops surviving and the crop refuses first, so the guard is never reached.
1. `scripts/measure-trace --measure-anyway shot.jpg` and compare its peak row against the PNG's. The JPEG must read higher. That is what the guard is protecting, stated as a number rather than as a worry.
1. Set `RAY_TOLERANCE` from the PNG's max deviation and `MAX_OFF_RAY` between the two captures' fractions, with the figures in a comment at each constant.
1. Confirm the crop still reports `drawable found at x=… y=…` and that `find_drawable` deriving from `BACKGROUND` changed nothing about where it lands.

**What a high off-ray fraction on the PNG would mean**, since that is the one result that changes the design rather than a constant:

| PNG's fraction    | Reading                                                          | Action                                                                        |
| ----------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| At or near 0%     | The capture path is identity across the range                    | Keep `MAX_OFF_RAY`, set `RAY_TOLERANCE` from the max deviation                |
| A few percent     | A mild transfer curve, or dithering in the compositor            | Raise both from the table; the margin to 32% is still large                   |
| Above roughly 10% | Colour management is real and the ray is not measurable this way | Fall back to a raised distinct-level threshold, and demote the ray to a print |

### Last: `fix: set the guard's thresholds from the measured captures (#64)`

The three constants with their measured values and the figures behind them, plus a "what landed differently" section appended to this plan if anything above turned out other than described.

## What landed differently

Recorded as the work went, rather than at the end.

- **A sixth commit arrived before the host run: `--explain`.** The plan said to set `RAY_TOLERANCE` from the largest deviation observed in a real PNG, and the tool had no way to report that: it printed one aggregate fraction computed at a tolerance already fixed. Adding the instrument as a throwaway probe beside the script would have been #38's mistake repeated, which is the mistake this whole issue exists to correct, so it went into the tool.
- **The `ruff` job's vacuous pass was real, and the mandatory control is what caught it.** `extend-include = ["measure-trace"]` matches nothing, because ruff globs with a literal path separator and a pattern without a `/` matches only at the repository root. With an unused import planted, that spelling reported "All checks passed".
- **ruff's default rule set is wider than its usual description** and found a real defect on its first run: `subprocess.run` with no explicit `check=`.
- **ruff formats Python fenced inside Markdown**, which would have put all 53 `.md` files in its remit and created a check that `ci.yml`'s `paths-ignore` prevents from ever seeing the changes that break it. Excluded.
- **`typos` needed `extend-identifiers`, not `extend-words`.** The tool splits an identifier into words before judging it, so the obvious entry suppresses nothing while reporting success. Same failure shape as the ruff glob, twice in one branch.
- **The crop refuses before the guard on a hard recompress.** A quality-40 JPEG destroys the exact background, so `find_drawable` fails first. Its message now names recompression as the second explanation, and the JPEG in the procedure above moved to quality 60 so the guard is actually reached.
- **The guard's margin is far wider than the provisional constants assumed.** Measured on synthetic captures reproducing the shader's arithmetic: 193 green levels in a lossless capture of a fading trace, against the threshold of 32 that used to refuse it, at 0.00% off the ray with a max deviation of 0.71 levels; against 32% to 43% for JPEG at every quality from 95 down to 60.
- **The host run refused a good capture, and the cause was the risk this plan listed.** A screenshot is written in the display's colour space rather than the framebuffer's, and `sips` reports the capture as Display P3, so the guard was comparing P3 numbers against an sRGB ray. **What identified it was the shape rather than the size of the deviation:** median 0.39, exactly the synthetic figure, with a small minority off by up to 55 levels. A codec bends every pixel a little; this bent the bright ones a lot and left the dark ones alone. The fix is a conversion to sRGB before anything is measured, which took the same capture from 2.7372% off the ray to 0.0074%, and red at green 200-240 from 119.0 to 70.9 against a predicted 70.9. The fallback in the risks section, demoting the ray to a printed diagnostic, was not needed.
- **The trap in it is that the error vanishes at black.** The background survives as exactly `RGB(5, 5, 8)`, so the capture looks faithful at precisely the point anyone would check it, and `AGENTS.md`'s standing advice to sample a background pixel would have confirmed a capture the tool could not measure. That bullet now says what it can and cannot establish.
- **No published number moved.** Green barely shifts under the conversion, so the rows this tool reports are identical before and after: the host capture's peak row is 459 either way. #38's tables stand.
- **The tolerance is a measured floor, not a preference.** On the real capture a tolerance of 1 puts a good picture at 0.9446%, above the 0.5% threshold, so it would refuse the very thing the tool exists to measure. 2 is the tightest that does not, and 3 buys nothing. `SATURATED` earns its place separately: removing the exclusion takes the same capture from 0.0074% to 0.1161% and its max deviation from 8.64 to 110.89, while where the cut falls does not matter at all, since 240, 250 and 254 are identical and the population removed sits at 255 exactly.
- **What the guard is protecting turned out to be far starker than the synthetic captures suggested.** On synthetic data a JPEG moved the peak row 149 to 141. On the real capture it moves it from row 459 to row 6: the same picture, measured through a quality-60 JPEG, reports the 0.5 sine as **+1.1002 and on the rail**. A tool that answered that without refusing would not be slightly wrong, it would report a signal 6.8 dB hot and clipping.
- **Provenance was not established for the capture, and it happens not to matter.** The plan's first host step is `zig build install-plugins` and reading both hash pairs; that was not run. The installed CLAP is `865a5e22fbbd`, which is #55's own verified build rather than this branch's. It is acceptable here for a reason that will not hold next time: **this branch changes no shipping code.** Its whole diff against `main` is a test-module import in `build.zig`, two doc-comment paragraphs in `src/gpu/iface.zig`, and test-only helpers and tests in `src/gpu/metal/renderer.zig`, so the picture measured is the picture this branch produces. Any issue that touches the renderer must do the install step properly.

## Out of scope

- **Rewriting it as an offscreen harness.** That is [#51](https://github.com/cboone/fosforo/issues/51), which reads a texture rather than a screenshot and needs neither the crop nor any guard. This issue is about not losing the working tool in the meantime.
- **The peak-row measurement's own retirement under persistence.** The tool will still find the topmost lit pixel in a column; that pixel just stops being this frame's sample once a trail is lit above it. This plan makes the tool *say* so and does not change what it measures.
- **Anything #60 breaks.** A tonemap and a palette end the green-channel isolation and the ray relation both. That issue already carries reworking this tooling; nothing here tries to anticipate it.
- **Pinning `pillow` and `numpy`.** The shebang keeps taking them unpinned through `uv`. Pinning tools that gate CI is this repository's rule; this script gates nothing automatic and informs a human.

## Risks to watch at the keyboard

- **A vacuous `ruff` job is the likeliest failure and it looks exactly like a pass.** `extend-include` is one line and an extensionless file is invisible without it. The planted unused import is not optional.
- **Colour management could break the ray at the bright end.** The background reading back as exactly `RGB(5, 5, 8)` is measured and says the capture path is identity at the low end; it says nothing about `G = 200`. If the PNG's off-ray fraction comes back high, the fallback recorded in the issue is a raised distinct-level threshold with the measured numbers behind it, and the ray check becomes a printed diagnostic rather than a gate.
- **`ruff format` will rewrap the long `add_argument` lines** unless `line-length` accommodates them. That is a formatting choice, not a defect; take whatever `ruff` produces rather than fighting it, and let the reformat land in the commit that introduces the tool.
- **The MSL anchors are the fragile half of the test.** Both function names appear in the file's header comment, and anchoring on the bare name finds the comment and then the wrong `float4(`. Anchor on the definition, and keep the negative test that proves a moved declaration reads as `null` rather than as a pass.
