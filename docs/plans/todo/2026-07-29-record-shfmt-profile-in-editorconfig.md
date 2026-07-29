# Record the shfmt profile in `.editorconfig` and enforce it in CI

Addresses [issue #15](https://github.com/cboone/fosforo/issues/15).

## Context

`cmake/narrow-au-resource-usage` is the repository's only shell script, and `shfmt` reports it as unformatted. It is not. The file conforms exactly to a coherent profile that the repository never wrote down, so every run of `shfmt` against its own defaults produces a diff that reads as a finding and is not one. This surfaced twice during issue #3 and was skipped both times as out of scope.

Reformatting to `shfmt`'s defaults would be the wrong direction: it would churn a self-consistent script that `cmake/CMakeLists.txt` depends on as a POST_BUILD step, and would record no decision, leaving the next person facing the same ambiguity from the other side. The fix is to record the profile the file already follows.

Two decisions extend the issue's minimum. The `.editorconfig` also carries verified whole-repository defaults, since the file has to exist anyway and an empty `[*]` section is a missed opportunity. And the shell tooling is wired into CI now rather than deferred, because the issue correctly notes that a recorded convention with no enforcement still rests on someone remembering to run the tool.

## What was verified

Everything below was confirmed empirically against the working tree with `shfmt` 3.13.1 and `shellcheck` 0.11.0, not assumed.

<!-- prettier-ignore -->
| Claim                                                    | Result                                                        |
| -------------------------------------------------------- | ------------------------------------------------------------- |
| Bare `shfmt -d` diffs the script                          | Yes, 7 hunks: redirects and `case` indentation                 |
| `shfmt -i 2 -ci -sr -d` is silent                         | Yes, exit 0                                                    |
| `shellcheck` is silent                                    | Yes, exit 0                                                    |
| `[*.sh]` reaches the extensionless script                 | **No.** Confirms the issue's third task                        |
| `[{*.sh,narrow-au-resource-usage}]` reaches it            | Yes, clean under bare `shfmt -d`                               |
| `.editorconfig` is found from any cwd and via `shfmt -d .`| Yes, including an absolute path from `/`                       |
| **Any formatting flag suppresses `.editorconfig`**        | **Yes.** `shfmt -i 2 -d` still diffs, and `-ln bash -d` does   |
| `shfmt -f .` finds the script by shebang                  | Yes, and it is the only shell file in the repository           |
| Repository is all LF, all ASCII/UTF-8                     | Yes, every tracked file                                        |
| Every file ends with a newline                            | Yes, none missing                                              |
| Trailing whitespace anywhere                              | None, including in Markdown                                    |
| Tab indentation anywhere                                  | None                                                           |
| Indent widths                                             | 4 for `.zig`/`.zon`/C/C++/Metal/CMake, 2 for YAML/JSON/TOML    |

The flag-suppression finding is the load-bearing one: it means `shfmt -d` is correct and `shfmt -i 2 -d` silently is not, which is counterintuitive enough to document in three places.

## Changes

### 1. Add `.editorconfig` (new file, repository root)

```ini
# https://editorconfig.org
#
# shfmt reads this file natively, which is why the shell section carries
# shfmt-specific keys. That support is all-or-nothing: passing any formatting
# flag makes shfmt ignore .editorconfig entirely, so `shfmt -d` is correct here
# and `shfmt -i 2 -d` silently is not.

root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true

# zig fmt is the authority for both. This only keeps editors from fighting it.
[*.{zig,zon}]
indent_style = space
indent_size = 4

[*.{c,cpp,h,metal}]
indent_style = space
indent_size = 4

[CMakeLists.txt]
indent_style = space
indent_size = 4

[*.{json,jsonc,toml,yml,yaml}]
indent_style = space
indent_size = 2

# markdownlint's MD009 already governs trailing whitespace here and allows the
# two spaces that mean a hard line break. Nothing relies on that today; this
# keeps the editor from stripping it before markdownlint can have an opinion.
[*.md]
trim_trailing_whitespace = false

# The script has no extension, so a bare [*.sh] section would not reach it.
# These four keys are the file's existing style recorded, not imposed: they are
# exactly `shfmt -i 2 -ci -sr`.
[{*.sh,*.bash,narrow-au-resource-usage}]
indent_style = space
indent_size = 2
switch_case_indent = true
space_redirects = true
```

Every indent value above matches what the tracked files already contain. `.zon` is included alongside `.zig` because `build.zig.zon` is 4-space and would otherwise fall through to editor defaults.

### 2. Add a `shell` job to `.github/workflows/ci.yml`

Modelled on the existing `shaders` job, which is likewise a standalone job the reusable workflow does not cover.

```yaml
  # The reusable Zig CI workflow's `format` job runs `zig fmt --check` and
  # nothing else, so the .editorconfig profile would otherwise rest on someone
  # remembering to run the tool locally. Ubuntu rather than macOS: both tools
  # are platform-independent static analysis, and the macOS runner bills at ten
  # times the rate. Both are pinned to the versions the profile was verified
  # against; the runner image ships shellcheck 0.9.0, which would drift out from
  # under this on the next image refresh.
  shell:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    env:
      SHFMT_VERSION: "3.13.1"
      SHELLCHECK_VERSION: "0.11.0"
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - name: Install shfmt and shellcheck
        run: |
          curl -sSfL -o shfmt \
            "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64"
          sudo install shfmt /usr/local/bin/shfmt
          curl -sSfL \
            "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
            | tar -xJf -
          sudo install "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck

      # No flags, deliberately: any formatting flag makes shfmt ignore
      # .editorconfig, which is the entire point of the file. `-f .` finds the
      # extensionless script by shebang, so neither step hardcodes a path that
      # has to be maintained as scripts are added.
      - name: Check shell formatting
        run: shfmt -d .

      - name: Lint shell scripts
        run: shfmt -f . | xargs -r shellcheck
```

Release binaries rather than a third-party setup action: it keeps the pin explicit and adds no new action to audit, consistent with how `clap-validator` is pinned by commit.

### 3. Drop `.editorconfig` from both `paths-ignore` lists in `ci.yml`

The lists already name `.editorconfig` in both the `push` and `pull_request` triggers, so the file was anticipated but never added. Once the `shell` job's result depends on that file, ignoring changes to it means a profile change skips the job it governs.

The tradeoff is worth stating: `paths-ignore` is workflow-level, so an `.editorconfig`-only change will now trigger every job in `ci.yml`, including the 30-minute `audio-unit-sandbox` build. Such changes should be rare, and a shell job blind to its own configuration is the worse failure.

### 4. Record the constraint in `AGENTS.md`

Add to the `## Development` block:

```bash
shfmt -d .                 # reads .editorconfig; passing any flag ignores it
shellcheck cmake/narrow-au-resource-usage
```

Add a `## Gotchas` bullet, matching the existing entries' shape:

> **`shfmt` reads `.editorconfig`, but only with no flags.** The shell profile (`-i 2 -ci -sr`) lives in `.editorconfig` because `cmake/narrow-au-resource-usage` was written to a style the repository never recorded, and bare `shfmt` reported it as unformatted. Passing any formatting flag makes `shfmt` discard `.editorconfig` wholesale, so `shfmt -d` is correct and `shfmt -i 2 -d` is not. The script has no extension, so the section names it directly; a `[*.sh]` section would not match. The `shell` CI job enforces both this and `shellcheck`.

### 5. Record the workflow in `CONTRIBUTING.md`

Add to `### Requirements`: `shfmt` and `shellcheck`, needed only when changing shell scripts.

Add to `## Code Style`, alongside the existing `zig fmt` line:

> - Run `shfmt -w .` before committing, with no flags. The shell profile lives in `.editorconfig`, and `shfmt` ignores that file if any formatting flag is passed
> - Keep `shellcheck` clean

Add to `## Pull Request Process` after the existing formatting step: `shfmt -d . && shfmt -f . | xargs shellcheck`.

## Files touched

<!-- prettier-ignore -->
| File                        | Change                                                        |
| --------------------------- | ------------------------------------------------------------- |
| `.editorconfig`             | New. The profile plus verified whole-repository defaults       |
| `.github/workflows/ci.yml`  | New `shell` job; `.editorconfig` removed from both ignore lists|
| `AGENTS.md`                 | Development commands and one Gotchas bullet                    |
| `CONTRIBUTING.md`           | Requirements, Code Style, Pull Request Process                 |

`cmake/narrow-au-resource-usage` is **not** modified. Its behavior must not change; the whole point is that the file was already correct.

## Verification

```bash
# The issue's acceptance criteria, both silent, both with no flags.
shfmt -d cmake/narrow-au-resource-usage
shellcheck cmake/narrow-au-resource-usage

# Generalized, which is what CI runs.
shfmt -d .
shfmt -f . | xargs shellcheck

# Negative control: proves .editorconfig is what makes the above pass,
# by confirming a flag suppresses it and the diff returns.
shfmt -i 2 -d cmake/narrow-au-resource-usage   # expect: a diff

# The script's behavior is unchanged, and the AUv2 plist is still stripped.
cmake -B build cmake/
cmake --build build --target fosforo_auv2
./cmake/narrow-au-resource-usage --check build/assets/Fosforo.component/Contents/Info.plist

# Nothing else regressed.
zig build test
zig fmt --check build.zig src/
markdownlint-cli2
```

Confirm the brace glob resolves as intended before relying on it, since only the two-alternative form was tested during planning:

```bash
shfmt -f . | xargs -I{} sh -c 'shfmt -d "{}" > /dev/null && echo "clean: {}"'
```

On the pull request, confirm the `shell` job appears and passes. It should start green: both tools already pass against the current tree.

## Commits

Three, each self-contained and reviewable:

1. `chore: record the shfmt profile in .editorconfig (#15)` — the new file alone
1. `ci: check shell formatting and lint shell scripts (#15)` — the `shell` job and the `paths-ignore` removal
1. `docs: document the shfmt profile and its no-flags constraint (#15)` — `AGENTS.md` and `CONTRIBUTING.md`
