# 0013. Distribute as a signed, notarized pkg installer

**Status:** Accepted

## Context

The plugin is authored once as a CLAP and projected outward with clap-wrapper (ADR 0003), which means a release is not one file. It is a `.clap` that belongs in `Audio/Plug-Ins/CLAP` and a `.component` that belongs in `Audio/Plug-Ins/Components`: two formats, two directories, neither of which a user has any reason to know about.

Every bundle the build produces is already signed, ad-hoc by default (issue #20), and supplying a real identity now also produces a secure timestamp and the hardened runtime (issue #24). None of that is distributable on its own. A macOS download that has not been notarized is refused by Gatekeeper with a dialog that does not distinguish "unnotarized" from "damaged", so notarization is not a polish step; it is the difference between a download that opens and one that appears broken.

`notarytool` accepts a zip, a dmg, or a pkg, and not a bare bundle, so the choice of container and the notarization design are one decision rather than two.

Three containers were considered:

- **A zip per format.** Simplest to produce, and `notarytool` takes it directly. But a zip is transport rather than an artifact: `stapler` cannot staple the archive, only the bundles inside it, and the user still has to know which folder each one goes in.
- **A dmg.** Conventional for Mac software, and staplable as a single file. It still presents two bundles the user must drag to two different directories, neither of which is visible in the Finder sidebar.
- **A pkg.** Staplable as a single file, and the only option that can place both bundles itself.

## Decision

Ship **one signed, notarized, stapled `.pkg`** containing both bundles.

The distribution offers the user a **choice of install domain**, the local system or their home directory, rather than forcing an admin password on someone installing for themselves.

The CLAP in the package is the **Zig-built** one, from `zig build`. The CMake build produces a second CLAP so CI can prove the clap-wrapper seam works, and that one is discarded at packaging time. The `.component` necessarily comes from CMake, because the Audio Unit exists only through clap-wrapper (ADR 0011).

Only the pkg is submitted for notarization, not the two bundles separately. Files laid down by an installer do not receive `com.apple.quarantine`, so the pkg's stapled ticket is the one Gatekeeper actually consults.

Signing and notarization run **locally, never in CI**. This repository is public. Hands-off tagged releases would require the Developer ID Application certificate, the Developer ID Installer certificate, both private keys, and App Store Connect credentials to live in repository secrets, and that is not a trade worth making for an operation performed rarely and deliberately.

## Consequences

**The user gets one download and no instructions.** This is the whole point, and it is the only option of the three that achieves it.

**Two certificates are needed, not one.** Bundles are signed with Developer ID *Application*; the pkg is signed with Developer ID *Installer*. They are distinct certificate types and easy to conflate. `security find-identity -v -p codesigning` does not list installer certificates at all, so a null result there is not evidence that one is missing; check with `security find-identity -v` and no policy.

**The release path is not exercised by CI and can rot.** Accepted, and the direct cost of keeping distribution keys out of a public repository. CI guards the one direction it can: `scripts/assert-adhoc-signature` asserts that the default build stays ad-hoc, unhardened and untimestamped, so the conditional that enables the release path cannot silently leak into the hermetic one. The positive direction is checked by hand, and the scripts under `scripts/` are the executable record of the procedure.

**The domain choice is the least-proven part.** `enable_currentUserHome` has the installer reinterpret an absolute install location relative to the user's home, which is what lets one distribution serve both choices, and its handling has historically been quirky. Both domains are tested explicitly. If it proves unreliable, the fallback is system-only, which is what nearly every commercial audio plugin installer already does.

**This does not commit the project to a version.** The machinery is built and exercised against a real artifact while `build.zig.zon` stays at `0.0.0`. Cutting v0.1.0 remains a Phase 6 decision.
