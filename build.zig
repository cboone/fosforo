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

    const clap_c = translateClap(b, target, optimize);
    const objc = b.dependency("objc", .{ .target = target, .optimize = optimize }).module("objc");

    // Two artifacts share one implementation, differing only in whether they
    // export the CLAP entry symbol themselves. See ADR 0003.
    //
    //   static  -> consumed by clap-wrapper, whose own entry.cpp defines
    //              clap_entry, so exporting it here would collide at link time
    //   dynamic -> the .clap bundle a CLAP host loads directly
    const impl = b.addLibrary(.{
        .name = "fosforo_impl",
        .linkage = .static,
        .root_module = coreModule(b, target, optimize, clap_c, objc, false),
    });
    b.installArtifact(impl);

    const plugin = b.addLibrary(.{
        .name = "fosforo",
        .linkage = .dynamic,
        .root_module = coreModule(b, target, optimize, clap_c, objc, true),
    });

    installClapBundle(b, plugin);
    addTestStep(b, target, optimize, clap_c, objc);
    addShaderValidationStep(b);
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

fn coreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    clap_c: *std.Build.Module,
    objc: *std.Build.Module,
    export_entry: bool,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "export_entry", export_entry);
    // Sentinel-terminated because it crosses the ABI as a C string.
    options.addOption([:0]const u8, "version", zon.version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("clap_c", clap_c);
    mod.addImport("objc", objc);
    mod.addImport("build_options", options.createModule());
    for (frameworks) |fw| mod.linkFramework(fw, .{});
    return mod;
}

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

fn addTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    clap_c: *std.Build.Module,
    objc: *std.Build.Module,
) void {
    const tests = b.addTest(.{
        .root_module = coreModule(b, target, optimize, clap_c, objc, false),
    });
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
