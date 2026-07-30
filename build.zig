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

    const core: Core = .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .clap_c = translateClap(b, target, optimize),
        .objc = b.dependency("objc", .{ .target = target, .optimize = optimize }).module("objc"),
    };

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
    b.installArtifact(impl);

    const plugin = b.addLibrary(.{
        .name = "fosforo",
        .linkage = .dynamic,
        .root_module = core.module(.{ .export_entry = true }),
    });

    installClapBundle(b, plugin);
    addTestStep(core);
    addShaderValidationStep(b);
    addSmokeSteps(core);
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
fn installClapBundle(b: *std.Build, plugin: *std.Build.Step.Compile) void {
    const contents: std.Build.InstallDir = .{ .custom = "Fosforo.clap/Contents" };

    const binary = b.addInstallFileWithDir(
        plugin.getEmittedBin(),
        .{ .custom = "Fosforo.clap/Contents/MacOS" },
        "Fosforo",
    );
    const plist = b.addInstallFileWithDir(b.path("macos/Info.plist"), contents, "Info.plist");

    b.getInstallStep().dependOn(&binary.step);
    b.getInstallStep().dependOn(&plist.step);

    const install_local = b.step("install-clap", "Copy the .clap into ~/Library/Audio/Plug-Ins/CLAP");
    const copy = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\dest="$HOME/Library/Audio/Plug-Ins/CLAP"
        \\mkdir -p "$dest"
        \\rm -rf "$dest/Fosforo.clap"
        \\cp -R "$1" "$dest/"
        \\echo "installed to $dest/Fosforo.clap"
        ,
        "sh",
    });
    copy.addDirectoryArg(.{ .cwd_relative = b.getInstallPath(.{ .custom = "Fosforo.clap" }, "") });
    copy.step.dependOn(b.getInstallStep());
    install_local.dependOn(&copy.step);
}

fn addTestStep(core: Core) void {
    const tests = core.b.addTest(.{ .root_module = core.module(.{}) });
    const run = core.b.addRunArtifact(tests);
    core.b.step("test", "Run unit tests").dependOn(&run.step);
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
    // It is there to be run by hand, with a cycle count the steps do not offer:
    // `zig-out/bin/fosforo-smoke appkit 5000`. Nothing in the build reads that
    // path, including the leak script, which is handed the binary directly.
    const install = b.addInstallArtifact(exe, .{});

    const smoke = b.step("smoke", "Run both halves of the GUI smoke harness");
    smoke.dependOn(addSmokeHalf(b, exe, install, "gpu"));
    smoke.dependOn(addSmokeHalf(b, exe, install, "appkit"));

    // Measured from outside the process, because a leak the harness could see is
    // one it already owns. The script rather than the raw command, because the
    // criterion is an absence and an absence has to be told apart from a `leaks`
    // that produced nothing: see the assertion order in its header.
    const leaks = b.step("smoke-leaks", "Cycle the editor under leaks --atExit (needs a window server)");
    const check = b.addSystemCommand(&.{"./scripts/smoke-leak-check"});
    check.addFileArg(exe.getEmittedBin());
    check.step.dependOn(&install.step);
    check.stdio = .inherit;
    check.has_side_effects = true;
    leaks.dependOn(&check.step);
}

/// One half, as its own step, so CI can require the half that needs no window.
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

    const step = b.step(
        b.fmt("smoke-{s}", .{half}),
        b.fmt("Run the {s} half of the GUI smoke harness", .{half}),
    );
    step.dependOn(&run.step);
    return step;
}
