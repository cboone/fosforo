const std = @import("std");

/// The plugin descriptor reports a version string to the host, and the manifest
/// already declares one. Reading it here keeps them from drifting apart.
const zon = @import("build.zig.zon");

/// Frameworks the plugin links against. Cocoa for the view, QuartzCore for the
/// Metal layer, CoreVideo for the display link.
const frameworks = [_][]const u8{ "Foundation", "Cocoa", "Metal", "QuartzCore", "CoreVideo" };

pub fn build(b: *std.Build) void {
    // Pin the minimum macOS version rather than inheriting the build machine's.
    // Without this, Zig stamps the host version onto the object and the linker
    // warns when clap-wrapper links it at its own deployment target. Keep in
    // step with macos/Info.plist and cmake/CMakeLists.txt.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // First, and before anything below reaches `b.dependency`. This is the only
    // step here that builds on a non-Apple target, and the graph below cannot even
    // be *described* on one: `b.dependency` runs a dependency's `build` function
    // at configure time, and zig-objc's calls `appleSDKPath`, which panics on any
    // OS that is not Darwin. So `zig build ring-race` on Linux aborted inside a
    // dependency's build script before a single step ran, which is what the first
    // CI run of the `ring-race` job did (#44). Fetching the tarball is a cost;
    // describing the graph is the failure, and only the second one is fatal.
    //
    // Everything past this line is macOS-only anyway (ADR 0001), so the early
    // return costs nothing: on Linux there is genuinely nothing else to build.
    addRingRaceStep(b);
    if (target.result.os.tag != .macos) return;

    const core: Core = .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .clap_c = translateClap(b, target, optimize),
        .objc = b.dependency("objc", .{ .target = target, .optimize = optimize }).module("objc"),

        // Deliberately below the early return above, so the one step that builds
        // off macOS never spawns a process it has no use for.
        .provenance = gitProvenance(b),
    };

    // Zig's own step, re-described. Its default text is "Copy build artifacts to
    // prefix path", which is accurate and is read next to two project steps whose
    // names also begin with "install" and which write somewhere else entirely. The
    // destination is the whole distinction between them, so it is stated where it
    // is actually read rather than left to `zig build --help`'s reader to infer.
    //
    // TopLevelStep is private, but install_tls is a public field, so this reaches
    // the description without naming the type.
    b.install_tls.description = "Assemble Fosforo.clap into zig-out (not a plug-in folder)";

    // Two artifacts share one implementation, differing only in whether they
    // export the CLAP entry symbol themselves. See ADR 0003.
    //
    //   static  -> consumed by clap-wrapper, whose own entry.cpp defines
    //              clap_entry, so exporting it here would collide at link time
    //   dynamic -> the .clap bundle a CLAP host loads directly
    const impl = b.addLibrary(.{
        .name = "fosforo_impl",
        .linkage = .static,
        .root_module = core.module(.{}),
    });

    // Deliberately not on the default install step. CMake is the only consumer of
    // this archive and it now builds the step below into a prefix of its own, so
    // installing it here would write a file nothing reads and make `zig build`
    // emit something other than the bundle AGENTS.md says it emits. Nothing is
    // type-checked less: the dynamic library below compiles the same modules.
    const install_impl = b.addInstallArtifact(impl, .{});
    b.step("impl", "Build libfosforo_impl.a alone, which is all CMake wants from Zig")
        .dependOn(&install_impl.step);

    const plugin = b.addLibrary(.{
        .name = "fosforo",
        .linkage = .dynamic,
        .root_module = core.module(.{ .export_entry = true }),
    });

    const audio_unit = addAudioUnitStep(b);
    installClapBundle(b, plugin, audio_unit);
    addTestStep(core);
    addShaderValidationStep(b);
    addSmokeSteps(core);
}

/// Which worktree and which commit a binary came from, stamped in so the question
/// can be answered from the installed file rather than from memory.
///
/// This repository is normally several worktrees competing for one plug-in folder,
/// and the failure that costs time is not a collision but an *unnoticed* one: the
/// installed bundle belongs to whichever worktree copied last, and a host loading
/// the wrong build reads as a pass. `scripts/install-plugins` already compares
/// hashes, which answers the question only when there is something in this worktree
/// to compare against; these three fields are what let it answer for a bundle
/// nobody here built. See ADR 0018.
const Provenance = struct {
    branch: [:0]const u8,
    commit: [:0]const u8,
    dirty: bool,

    /// What every field reads when git cannot answer, which is a supported state
    /// rather than an error. `build.zig.zon`'s `.paths` publishes this package as a
    /// tarball of src, shaders, cmake, scripts and three files, none of which is a
    /// repository, and that tarball must still build.
    const unknown: Provenance = .{ .branch = "unknown", .commit = "unknown", .dirty = false };
};

/// Ask git what this build is, at configure time, and degrade rather than fail.
///
/// **This does not weaken the hermetic build ADR 0009 protects, and the precedent is
/// stronger than the one /usr/bin/codesign sets below.** A plain `zig build` already
/// spawns a process before reaching this line: `b.dependency("objc", ...)` runs
/// zig-objc's build function at configure time, which calls `appleSDKPath` and so
/// `std.zig.system.darwin.getSdk`, whose own comment reads "This executes `xcrun` to
/// get the SDK path". Nothing here can link Cocoa or Metal without the SDK that call
/// finds, so a working Xcode or Command Line Tools install is already a hard
/// requirement. `git` is strictly weaker than that: it needs no network, and where
/// `xcrun` failing is fatal, `git` failing lands on `Provenance.unknown`.
fn gitProvenance(b: *std.Build) Provenance {
    const root = b.build_root.path orelse return .unknown;

    // Two calls rather than one, and that is measured rather than stylistic.
    // `git rev-parse --abbrev-ref HEAD --short HEAD` prints the branch name
    // **twice**: `--abbrev-ref` is sticky across every ref that follows it, so the
    // field meant to carry the commit silently carries the branch. A provenance
    // line that is wrong while still looking well-formed is worse than none.
    const branch = gitOutput(b, root, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) orelse return .unknown;
    const commit = gitOutput(b, root, &.{ "rev-parse", "--short", "HEAD" }) orelse return .unknown;

    // `--porcelain` respects .gitignore, so neither zig-out/ nor build/ registers.
    // A failure here is treated as clean rather than as unknown: the two calls above
    // have already succeeded, so git is present and this is a repository.
    const status = gitOutput(b, root, &.{ "status", "--porcelain" }) orelse "";

    return .{
        // A detached HEAD reports the literal string "HEAD", which is not a branch
        // name and must not be printed as one. CI is always detached: no checkout in
        // .github/ sets `fetch-depth`, so actions/checkout gives depth 1 with HEAD
        // detached, and on a pull_request the commit is the ephemeral merge rather
        // than the branch head.
        .branch = if (std.mem.eql(u8, branch, "HEAD")) "detached" else branch,
        .commit = commit,
        .dirty = status.len != 0,
    };
}

/// One `git` invocation, trimmed, or null if git could not answer.
fn gitOutput(b: *std.Build, root: []const u8, args: []const []const u8) ?[:0]const u8 {
    const argv = b.allocator.alloc([]const u8, args.len + 3) catch @panic("OOM");

    // Absolute, on the precedent signClapBundle sets for /usr/bin/codesign: a `git`
    // earlier in PATH would otherwise decide what a shipped binary claims about
    // itself. `-C` rather than the build runner's working directory, which is where
    // `zig build` was invoked from and need not be the build root.
    argv[0] = "/usr/bin/git";
    argv[1] = "-C";
    argv[2] = root;
    @memcpy(argv[3..], args);

    // `runAllowFail` rather than `b.run`, which calls `process.fatal`: every failure
    // reachable here is a state this build supports. `.ignore` keeps git's
    // "fatal: not a git repository" off a terminal where it would read as an error.
    var code: u8 = undefined;
    const raw = b.runAllowFail(argv, &code, .ignore) catch return null;

    return b.allocator.dupeZ(u8, std.mem.trim(u8, raw, " \t\r\n")) catch @panic("OOM");
}

/// Build the Audio Unit, which is a CMake artifact this build system knows nothing
/// about beyond how to ask for it.
///
/// The two constraints on that request used to exist only as prose. Configuring is
/// once per worktree and building is every time, and `--target fosforo_auv2` does
/// not build the CLAP because setting AUV2_MANUFACTURER_CODE sends
/// make_clapfirst_plugins down a branch that adds no dependency between the two
/// targets. Both now live in the script, which is also what CI runs, so neither can
/// be true only locally.
///
/// Returns the run step rather than the top-level step, so the install steps below
/// can depend on the work rather than on the name.
fn addAudioUnitStep(b: *std.Build) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"./scripts/build-audio-unit"});
    run.stdio = .inherit;
    run.has_side_effects = true;

    const step = b.step("audio-unit", "Build Fosforo.component into build/assets, through CMake");
    step.dependOn(&run.step);
    return run;
}

/// Build the CLAP bindings.
///
/// Zig 0.16's translate-c mishandles `#pragma once` when the same header is
/// reached through two spellings, which CLAP does constantly via `../x.h`
/// includes. Running the file through clang's preprocessor first collapses it
/// to a single translation unit with no includes left to alias.
///
/// The cost is that object-like macros are consumed rather than translated.
/// The ones that matter are re-declared and checked in src/clap/c.zig.
fn translateClap(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const clap_dep = b.dependency("clap", .{});

    const preprocess = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-P" });
    preprocess.addPrefixedDirectoryArg("-I", clap_dep.path("include"));
    preprocess.addFileArg(b.path("src/clap/clap_all.h"));
    preprocess.addArg("-o");
    const preprocessed = preprocess.addOutputFileArg("clap_preprocessed.h");

    const translate = b.addTranslateC(.{
        .root_source_file = preprocessed,
        .target = target,
        .optimize = optimize,
    });
    return translate.createModule();
}

/// Everything every artifact built from this source has in common, gathered so
/// the call sites do not each thread five arguments through.
const Core = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    clap_c: *std.Build.Module,
    objc: *std.Build.Module,

    /// Resolved once in `build` rather than per module, so the four artifacts
    /// cannot disagree about which commit they came from.
    provenance: Provenance,

    const Options = struct {
        /// The module's root source file, which is also what bounds
        /// `@embedFile` and relative `@import`. Every root here has to sit
        /// directly in src/ for that reason: a root one directory deeper would
        /// put the rest of src/ out of reach and break the shader import below.
        root: []const u8 = "src/main.zig",
        export_entry: bool = false,
    };

    fn module(self: Core, options: Options) *std.Build.Module {
        const b = self.b;

        const build_options = b.addOptions();
        build_options.addOption(bool, "export_entry", options.export_entry);
        // Sentinel-terminated because it crosses the ABI as a C string.
        build_options.addOption([:0]const u8, "version", zon.version);

        // The facts, not the formatting: src/build_info.zig owns every string
        // composed from these, so no consumer restates one. The values feed the
        // module's cache key, which is why the first build after a commit is a full
        // rebuild and why the dirty flag flips at most once per editing session.
        build_options.addOption([:0]const u8, "git_branch", self.provenance.branch);
        build_options.addOption([:0]const u8, "git_commit", self.provenance.commit);
        build_options.addOption(bool, "git_dirty", self.provenance.dirty);

        const mod = b.createModule(.{
            .root_source_file = b.path(options.root),
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = true,
        });
        mod.addImport("clap_c", self.clap_c);
        mod.addImport("objc", self.objc);
        mod.addImport("build_options", build_options.createModule());

        // Shaders are compiled at runtime from source embedded in the binary
        // (ADR 0009). `@embedFile` resolves relative to the importing file and
        // cannot escape the module root, which is src/, so the file is reached
        // through the import table instead. Keeping shaders/ outside src/ is what
        // lets `zig build validate-shaders` treat it as a directory of shaders
        // rather than of Zig.
        mod.addAnonymousImport("scope.metal", .{ .root_source_file = b.path("shaders/scope.metal") });
        for (frameworks) |fw| mod.linkFramework(fw, .{});
        return mod;
    }
};

/// Assemble the loadable macOS bundle a CLAP host expects:
///
///   Fosforo.clap/Contents/Info.plist
///   Fosforo.clap/Contents/MacOS/Fosforo
fn installClapBundle(
    b: *std.Build,
    plugin: *std.Build.Step.Compile,
    audio_unit: *std.Build.Step.Run,
) void {
    const contents: std.Build.InstallDir = .{ .custom = "Fosforo.clap/Contents" };

    const binary = b.addInstallFileWithDir(
        plugin.getEmittedBin(),
        .{ .custom = "Fosforo.clap/Contents/MacOS" },
        "Fosforo",
    );
    const plist = b.addInstallFileWithDir(b.path("macos/Info.plist"), contents, "Info.plist");

    b.getInstallStep().dependOn(&binary.step);
    b.getInstallStep().dependOn(&plist.step);

    signClapBundle(b, binary, plist);

    addInstallSteps(b, audio_unit);
}

/// The two steps that write to ~/Library/Audio/Plug-Ins, and the one that builds
/// both bundles without leaving the worktree.
///
/// One invariant holds across both install steps and is the reason they are worth
/// distinguishing at all: **each builds exactly what it installs, and verifies what
/// landed**. Before this, both built the CLAP and neither built the Audio Unit, so
/// `install-plugins` installed a component only if some earlier command in some
/// earlier session happened to have produced one. A worktree that had never run
/// CMake kept whatever component another branch had installed, said nothing about
/// it, and Logic loaded that instead (#43).
///
/// Neither runs an install of its own. `scripts/install-plugins` is the single
/// implementation of "copy a bundle into a plug-in folder and prove it landed", and
/// `install-clap` reaches it through --clap-only rather than through the inline
/// `cp -R` it used to carry, which could not say what it had copied.
fn addInstallSteps(b: *std.Build, audio_unit: *std.Build.Step.Run) void {
    const both = b.step(
        "plugins",
        "Build both bundles into the worktree, without installing either",
    );
    both.dependOn(b.getInstallStep());
    both.dependOn(&audio_unit.step);

    const install_clap = b.addSystemCommand(&.{ "./scripts/install-plugins", "--clap-only" });
    install_clap.step.dependOn(b.getInstallStep());
    install_clap.stdio = .inherit;
    install_clap.has_side_effects = true;
    b.step(
        "install-clap",
        "Build the CLAP, install it into ~/Library/Audio/Plug-Ins, and verify what landed",
    ).dependOn(&install_clap.step);

    const install_both = b.addSystemCommand(&.{"./scripts/install-plugins"});
    install_both.step.dependOn(b.getInstallStep());
    install_both.step.dependOn(&audio_unit.step);
    install_both.stdio = .inherit;
    install_both.has_side_effects = true;
    b.step(
        "install-plugins",
        "Build BOTH bundles, install them into ~/Library/Audio/Plug-Ins, and verify what landed",
    ).dependOn(&install_both.step);
}

/// Sign the assembled bundle, ad-hoc unless told otherwise.
///
/// The linker already ad-hoc signs the dylib, which is automatic on arm64 and is why
/// a host can load it at all. That leaves the *bundle* unsigned: with no
/// Contents/_CodeSignature, `codesign --verify` reports "code has no resources but
/// signature indicates they must be present". cmake/CMakeLists.txt does the same for
/// the two bundles it builds.
///
/// A real identity additionally gets --timestamp and --options runtime, because
/// notarization rejects a submission missing either. Both are conditional on the
/// identity rather than being separate switches, so a distributable signature cannot
/// be half-configured: there is one knob and it is the one you already had to set.
/// Neither belongs on the ad-hoc path. --timestamp contacts Apple's timestamp server,
/// which would make `zig build` need the network, and an ad-hoc signature has no
/// certificate whose expiry a timestamp could outlive. The hardened runtime is inert
/// here for a different reason: entitlements and runtime restrictions attach to a
/// process, and a plugin is loaded into the host's, so the host's apply. It is set
/// because notarization checks for it, not because it changes how this code runs.
///
/// This does not weaken the hermetic build ADR 0009 protects. /usr/bin/codesign ships
/// with macOS and is not an on-demand Xcode component the way the Metal toolchain is.
/// Named by absolute path rather than resolved through PATH, so that claim is enforced
/// rather than assumed: a wrapper or shim earlier in PATH would otherwise sign these
/// bundles instead, silently. ADR 0001 makes this macOS-only, so the path costs no
/// portability.
///
/// Depends on the two install steps individually rather than on the install step,
/// which is what avoids a cycle: the install step is the thing that depends on this.
/// A Run step with no output arguments reports side effects and is never cached, so
/// this re-runs on every build. Re-signing is idempotent and costs milliseconds.
fn signClapBundle(
    b: *std.Build,
    binary: *std.Build.Step.InstallFile,
    plist: *std.Build.Step.InstallFile,
) void {
    const identity = b.option(
        []const u8,
        "codesign-identity",
        "codesign identity for the .clap bundle ('-' signs ad-hoc)",
    ) orelse "-";

    const sign = b.addSystemCommand(&.{ "/usr/bin/codesign", "--force", "--sign", identity });

    // Before addDirectoryArg, not after: the bundle path is positional and codesign
    // wants it last.
    if (!std.mem.eql(u8, identity, "-")) {
        sign.addArgs(&.{ "--timestamp", "--options", "runtime" });
    }

    sign.addDirectoryArg(.{ .cwd_relative = b.getInstallPath(.{ .custom = "Fosforo.clap" }, "") });
    sign.step.dependOn(&binary.step);
    sign.step.dependOn(&plist.step);
    b.getInstallStep().dependOn(&sign.step);
}

/// The unit tests, and the two imports that exist only for them.
///
/// `scripts/measure-trace` restates four constants this project owns, two from
/// `src/gpu/iface.zig` and two from `shaders/scope.metal`, with nothing in Python
/// or MSL linking any of them. `scripts/read-provenance` restates one, the marker
/// prefix `src/build_info.zig` stamps into every binary, with nothing in shell
/// linking it either. Both tests read the script as text, the way the shader tests
/// read the embedded shader source, so both files have to be reachable through the
/// import table.
///
/// **Added to the test module alone, deliberately.** `Core.module` builds the
/// module every shipping artifact compiles from, and registering these there would
/// put a Python script and a shell script within reach of `@embedFile` in a release
/// build. Each call to `Core.module` is a separate `createModule`, so these imports
/// exist in exactly one of the two and that is structural rather than something to
/// measure afterwards.
fn addTestStep(core: Core) void {
    const b = core.b;
    const mod = core.module(.{});
    mod.addAnonymousImport("measure-trace", .{
        .root_source_file = b.path("scripts/measure-trace"),
    });
    mod.addAnonymousImport("read-provenance", .{
        .root_source_file = b.path("scripts/read-provenance"),
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run.step);
}

/// Shaders are compiled at runtime from embedded source (ADR 0009), so the
/// build never needs the Metal toolchain. That leaves syntax errors to surface
/// when the GUI opens, which this step closes.
///
/// Deliberately not wired into `zig build test`: making the test step depend on
/// an on-demand Xcode component would break the hermetic build ADR 0009 exists
/// to protect.
fn addShaderValidationStep(b: *std.Build) void {
    const step = b.step("validate-shaders", "Type-check Metal shaders (requires the Metal toolchain)");
    const check = b.addSystemCommand(&.{
        "xcrun", "-sdk", "macosx", "metal", "-x", "metal", "-fsyntax-only",
    });
    check.addFileArg(b.path("shaders/scope.metal"));
    step.dependOn(&check.step);
}

/// The GUI smoke harness (src/smoke.zig and ADR 0013), which is the only thing
/// here that runs a Metal or an AppKit call rather than type-checking one.
///
/// Deliberately not wired into `zig build test`, on `addShaderValidationStep`'s
/// precedent and ADR 0009's reasoning: making the default test path depend on a
/// machine capability reintroduces exactly the non-hermetic build that ADR
/// exists to prevent. The two halves are separate steps because their
/// requirements are, a device for one and a window server as well for the other.
fn addSmokeSteps(core: Core) void {
    const b = core.b;

    const exe = b.addExecutable(.{
        .name = "fosforo-smoke",
        .root_module = core.module(.{ .root = "src/smoke.zig" }),
    });

    // Not `b.installArtifact`. Plain `zig build` is the day-to-day loop and must
    // keep producing only the .clap, so the harness reaches zig-out/bin only when
    // a smoke step is what was asked for. Every smoke step below depends on this,
    // which is what makes that claim true rather than merely intended.
    //
    // It is there to be run by hand at a depth the steps do not reach:
    // `zig-out/bin/fosforo-smoke appkit 5000`. The run steps below pass no count
    // at all and take the harness's own default of 10; `smoke-leaks` is the one
    // that offers one, for the reason in its own comment.
    const install = b.addInstallArtifact(exe, .{});

    // Three halves now. `gpu` and `trace` need a device and no window, which is
    // what lets CI require both; `appkit` needs a window server and runs there
    // under `continue-on-error` (ADR 0013). They are registered in that order so
    // running `smoke` locally reports the cheap failures first.
    const smoke = b.step("smoke", "Run every half of the smoke harness");
    smoke.dependOn(addSmokeHalf(b, exe, install, "gpu"));
    smoke.dependOn(addSmokeHalf(b, exe, install, "trace"));
    smoke.dependOn(addSmokeHalf(b, exe, install, "appkit"));

    // Measured from outside the process, because a leak the harness could see is
    // one it already owns. The script rather than the raw command, because the
    // criterion is an absence and an absence has to be told apart from a `leaks`
    // that produced nothing: see the assertion order in its header.
    const leaks = b.step("smoke-leaks", "Cycle the editor under leaks --atExit (needs a window server)");
    const check = b.addSystemCommand(&.{"./scripts/smoke-leak-check"});

    // The one smoke step whose depth is worth setting from outside, because it is
    // the one whose cost is proportional to it and the one CI runs. The harness
    // waits on vsync roughly thirteen times per cycle, so a cycle costs about
    // 158 ms at 120 Hz and about 267 ms at 60 Hz, and a hosted runner refreshes at
    // the lower of those: 400 cycles is around two minutes there against fifty-odd
    // seconds here. CI passes 40, which still reaches `plugin.destroy`'s teardown
    // ten times and each of `oneCycle`'s four resizes forty.
    //
    // **Nothing is passed when the option is absent**, so `DEFAULT_CYCLES` in the
    // script stays the only place the default is written. Restating 400 here would
    // make it two places that have to agree, and the script is where the reasoning
    // for the number lives.
    if (b.option(u32, "leak-cycles", "Editor open/close cycles for smoke-leaks (default: the script's 400)")) |cycles| {
        check.addArgs(&.{ "--cycles", b.fmt("{d}", .{cycles}) });
    }

    check.addFileArg(exe.getEmittedBin());
    check.step.dependOn(&install.step);
    check.stdio = .inherit;
    check.has_side_effects = true;
    leaks.dependOn(&check.step);
}

/// The race harness (src/ring_race.zig and ADR 0016), which runs `Ring.write`
/// and `Ring.read` on two threads under Thread Sanitizer.
///
/// **The only step here that cannot run on the machine this project is developed
/// on.** Zig 0.16 links a `-fsanitize-thread` binary on `aarch64-macos` that
/// segfaults before `main`, re-measured on 0.16.0 rather than inherited. The
/// container is the one part of the signal path with no reason to stay on that
/// target: `src/dsp/ring.zig` imports `std` and nothing else. So this step wants
/// a Linux host, and CI supplies one. That is the same bargain
/// `addShaderValidationStep` and `addSmokeSteps` already make, a step allowed to
/// require a machine capability the default build must not depend on, with the
/// capability here being *not* macOS.
///
/// Deliberately not wired into `zig build test`, for their reasons and ADR 0009's.
fn addRingRaceStep(b: *std.Build) void {
    const step = b.step("ring-race", "Race-check the history buffer under Thread Sanitizer (needs a Linux host)");

    // Its own module rather than `Core.module`. That constructor adds `objc`,
    // the translated CLAP header, the anonymous shader import and five Apple
    // frameworks unconditionally, none of which can link off macOS.
    //
    // `resolveTargetQuery(.{})` rather than the shared target, which carries
    // `os_version_min` 11.0 as a macOS deployment floor. Resolved on Linux that
    // becomes a minimum kernel version no kernel satisfies. The ring has no
    // deployment target, so it takes the bare host.
    //
    // `link_libc` is load-bearing rather than incidental: Thread Sanitizer learns
    // about threads by intercepting `pthread_create`, and without libc Zig issues
    // a raw `clone` that TSan never sees. Both arms then come back clean, which is
    // the exact false pass the harness's control arm exists to catch.
    //
    // Debug, matching `zig build test`. Atomic orderings survive every
    // optimization level, so this costs no coverage.
    const target = b.resolveTargetQuery(.{});
    const exe = b.addExecutable(.{
        .name = "fosforo-ring-race",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ring_race.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .sanitize_thread = true,
        }),

        // **`sanitize_thread` alone produces a binary that detects nothing, and
        // says nothing about it.** Zig 0.16 defaults to its self-hosted x86_64
        // backend for a Debug build on Linux, and that backend links the Thread
        // Sanitizer runtime while emitting none of its instrumentation. The
        // result builds, links, runs, exits zero and reports no races, whatever
        // you race in it. Measured by disassembling both: the default backend
        // stores straight to the shared word, and `-fllvm` emits a
        // `__tsan_write8` call before the same store.
        //
        // The first run of this job with a deliberately racing control arm
        // reported nothing, which is exactly what that arm is for.
        .use_llvm = true,
    });

    // Refuse rather than produce a binary that segfaults before it can say why.
    // A cross-compiled harness is still worth building, so `-Dtarget` is not what
    // is consulted here: the question is whether *this* host can run one.
    if (b.graph.host.result.os.tag != .linux) {
        const fail = b.addFail(
            \\`zig build ring-race` needs a Linux host.
            \\
            \\Thread Sanitizer links on aarch64-macos and segfaults before main, which
            \\is why this check lives in the `ring-race` job on ubuntu-latest. See
            \\docs/adr/0016-verify-the-ring-ordering-with-tsan.md.
            \\
            \\To compile-check the harness from here without running it:
            \\    zig build-exe src/ring_race.zig -fsanitize-thread -lc -target x86_64-linux-gnu
        );

        // Still built, so a type error in the harness fails this step on macOS
        // rather than waiting for CI. Zig analyses a declaration only where it is
        // reached, so building it is what checks it.
        fail.step.dependOn(&exe.step);
        step.dependOn(&fail.step);
        return;
    }

    // Not `b.installArtifact`: plain `zig build` must keep producing only the
    // .clap, on `addSmokeSteps`' reasoning.
    const install = b.addInstallArtifact(exe, .{});

    // The script rather than the two runs, because the criterion is an absence
    // and an absence has to be told apart from an instrument that was not
    // running. See the assertion order in its header.
    const check = b.addSystemCommand(&.{"./scripts/ring-race-check"});
    check.addFileArg(exe.getEmittedBin());
    check.step.dependOn(&install.step);
    check.stdio = .inherit;
    check.has_side_effects = true;
    step.dependOn(&check.step);
}

/// One half, as its own step, so CI can require the halves that need no window.
fn addSmokeHalf(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    half: []const u8,
) *std.Build.Step {
    const run = b.addRunArtifact(exe);
    run.addArg(half);
    run.step.dependOn(&install.step);

    // Both matter, and for the same reason. `.inherit` is what lets the harness
    // narrate: a run step that buffers its output defeats the whole argument for
    // an executable over a test artifact. `has_side_effects` is what stops the
    // build runner reporting a cached result for a check whose entire subject is
    // the machine it is running on.
    run.stdio = .inherit;
    run.has_side_effects = true;

    // "GUI" dropped from the description when the third half arrived: `gpu` never
    // opened a window and `trace` does not either, so two of the three were being
    // described by the one requirement they do not have.
    const step = b.step(
        b.fmt("smoke-{s}", .{half}),
        b.fmt("Run the {s} half of the smoke harness", .{half}),
    );
    step.dependOn(&run.step);
    return step;
}
