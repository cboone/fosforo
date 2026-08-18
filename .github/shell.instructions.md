---
applyTo: "scripts/**,cmake/**,**/*.sh,**/*.bash"
---

# Shell script review instructions

Scripts in `scripts/` and `cmake/` have no file extension. They are Bash, identified by shebang, and `.editorconfig` records their style as exactly `shfmt -i 2 -ci -sr`.

- **`errexit` is suppressed inside functions called from a condition.** Assertion helpers such as `assert_adhoc` and `assert_distributable` are invoked only as `if ! helper ...; then`, and Bash disables `set -e` for the whole dynamic extent of a call whose status is being tested. A failing command substitution inside one of those functions does **not** exit the script. Do not report it as an early-exit bug. Flag it only for a function that is also called bare, and say which call site.
- **Assertion helpers return distinct non-zero codes on purpose.** `1` means the thing being asserted is wrong, `2` means the input carries no signature at all. `main` maps them to the `sysexits`-style codes in each script's header comment. Do not suggest collapsing them into a single truthy return.
- **Exit codes follow `sysexits`:** `64` invalid arguments, `65` the assertion failed, `66` the input is missing or unreadable, `70` an underlying tool failed. Check a change against the script's own header before flagging an exit code.
- **`shfmt` must be run with no parser or printer options.** Passing any of `-ln -p -s -i -bn -ci -sr -kp -fn -mn` makes it discard `.editorconfig` wholesale. Do not suggest adding `-i 2`. The output selectors `-d`, `-w`, `-l` and `-f` are safe.
- **Select files with `git ls-files`, never by walking the tree.** `shfmt` does not read `.gitignore`, so `shfmt -d .` reaches vendored scripts under `build/` once the CMake build has run.
- **`/usr/bin/codesign` is named by absolute path deliberately**, so a wrapper or shim earlier in `PATH` cannot sign these bundles silently. Do not suggest resolving it through `PATH` or `command -v`.
