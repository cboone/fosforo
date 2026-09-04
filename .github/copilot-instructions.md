# GitHub Copilot Instructions for fosforo

For full project conventions, see AGENTS.md in the repository root.

## PR Review

- **Anything under `docs/` has its own instructions**: see `.github/docs.instructions.md` for how plans and ADRs record decisions, why point-in-time statements are deliberate, and why the pull request description is not the authority on what has merged. The done-plans rule that used to sit here now lives there with the rest.
- **CLAP extensions have a direction, and `clap.log` runs the other way**: This plugin *provides* exactly three extensions, the three `getExtension` in `src/clap/plugin.zig` answers to: `audio-ports`, `state` and `gui`. `clap.log` is a **host** extension, fetched from `clap_host.get_extension` and consumed by `src/clap/log.zig`. The presence of that file is not evidence of a fourth provided extension, and a count of three is correct wherever the provided ones are being counted. Check which side of `get_extension` a name sits on before reporting a count as wrong.
- **Omitted relative pronouns are intentional**: This project's prose drops `that` and `which` in restrictive relative clauses where the pronoun is the object of the clause, as in "the validation ADR 0003 calls for", "the failures it catches", or "the historical record they are". This is standard English, not a grammar error. Do not flag it as a missing word. Flag it only when the omission creates a genuine garden path, and say which reading is the wrong one.
