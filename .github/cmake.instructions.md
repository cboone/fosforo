---
applyTo: "**/CMakeLists.txt"
---

# CMake review instructions

`cmake/CMakeLists.txt` is not the main build. `zig build` alone produces the loadable `.clap`; CMake exists only to project that outward into the AUv2 Audio Unit through clap-wrapper (ADR 0003). It is the only place in the repository where a second build system drives the first.

- **An unquoted `${VAR}` splits on semicolons, not on whitespace.** Semicolon is CMake's list separator, and it is the only thing unquoted expansion splits on. A variable holding a path with spaces expands to one argument, including inside `COMMAND`, and `VERBATIM` escapes it for the shell afterwards. Measured by reading the generated `build.make`: an unquoted variable holding `one two` emits `"one two"`, byte for byte what the quoted form emits. Do not report a path containing spaces as an argument-splitting bug. Flag missing quotes only where a semicolon is plausible, and say so explicitly.
- **`POST_BUILD` command order on the AUv2 target is load-bearing.** `narrow-au-resource-usage` and `set-au-display-name` rewrite `Contents/Info.plist`, and the signing command seals that plist into `CodeResources`. Signing must stay last. A fourth `POST_BUILD` command belongs above `fosforo_sign_bundle`, never below it. Do not suggest reordering these.
- **`/usr/bin/codesign` is named by absolute path deliberately,** and not found through `find_program` the way `zig` is. Zig's location genuinely varies; this one does not, and resolving it through `PATH` would let a shim sign these bundles silently. Do not suggest `find_program` for it.
- **The Zig custom target runs the `impl` step under its own `--prefix`, on purpose.** A bare `zig build` there would also reassemble and ad-hoc sign `zig-out/Fosforo.clap`, clobbering a Developer ID signature, and an `impl` step without the prefix would race a concurrent Debug build over `zig-out/lib`. Do not suggest simplifying either half back out.
- **`FetchContent` pins clap-wrapper to a commit rather than a tag,** because `make_clapfirst_plugins` postdates v0.9.1 and is in no tagged release. Do not suggest moving to a tag or a version range.
- **`CMAKE_CXX_STANDARD`, `CMAKE_OSX_DEPLOYMENT_TARGET` and `CLAP_WRAPPER_DOWNLOAD_DEPENDENCIES` are set here because clap-wrapper does not set them when consumed as a subproject.** They look redundant and are not. The deployment target is `11.0` and must stay in step with `build.zig` and `macos/Info.plist`.
- **AUv3 is deliberately absent** from `FOSFORO_FORMATS` (ADR 0011). Do not suggest adding it.
