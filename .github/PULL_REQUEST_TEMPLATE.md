<!-- markdownlint-disable MD041 relative-links -->

## Description

<!-- Describe your changes -->

## Related Issue

<!-- Link to the issue this PR addresses -->

Fixes #

## Type of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)
- [ ] Documentation update

## Checklist

- [ ] I have read the [CONTRIBUTING](../CONTRIBUTING.md) guide
- [ ] My code follows the project's style guidelines
- [ ] I have added tests that prove my fix/feature works
- [ ] All new and existing tests pass (`zig build test`)
- [ ] Formatting passes (`zig fmt --check build.zig src/`)
- [ ] The spell check passes (`typos`)
- [ ] If I touched a shell script, `shfmt -d` and `shellcheck` are both silent (see CONTRIBUTING for the `git ls-files` pipeline)
- [ ] If I touched `scripts/measure-trace`, `ruff format --check .` and `ruff check .` are both clean
- [ ] If I touched any Markdown, I ran `npm ci` first, then `npm run format` and `npm run lint:md` are both clean (never `markdownlint-cli2 --fix`, which rewrites every file its globs match rather than the ones you name). `npm ci` is what makes those the pinned versions; without it they silently fall through to whatever is installed globally
- [ ] I have updated CHANGELOG.md if this is a user-facing change
- [ ] I have updated the documentation if needed
- [ ] If this changes a settled architecture decision, I have added a superseding ADR in `docs/adr/`
