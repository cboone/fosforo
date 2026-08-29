//! What this build is, in the two shapes anything here needs to read it.
//!
//! `build.zig` supplies the facts (branch, commit, dirty) and this file owns every
//! string composed from them, so no consumer restates a format. Two shapes, and they
//! differ because their readers do:
//!
//!   `marker`             a line in the binary, for a script to grep out of a file
//!                        nobody in this worktree built. Also what `plugin.init` and
//!                        the smoke harness log, which is what keeps its bytes live
//!   `descriptor_version` semver build metadata, for the host to display
//!
//! **There is deliberately no short `branch commit` form here.** One was written and
//! removed: `scripts/read-provenance --short` already derives it from the marker, and
//! a second declaration of the same format in a second language is exactly what this
//! module exists to prevent. A Zig caller that wants one should log the marker.
//!
//! The problem all three exist for is in ADR 0018: several worktrees compete for one
//! plug-in folder, the installed bundle belongs to whichever copied last, and a host
//! loading the wrong build reads as a pass rather than as a failure.
//!
//! **Nothing here varies the plugin's identity.** The CLAP `id`, the AU triple and
//! the display name are the same in every build, deliberately; see ADR 0018 for why
//! the display name in particular is not suffixed.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;

/// The version `build.zig.zon` declares, without provenance. Kept separate because
/// `descriptor_version` must remain readable as this string plus a suffix.
pub const version: [:0]const u8 = build_options.version;

pub const branch: [:0]const u8 = build_options.git_branch;
pub const commit: [:0]const u8 = build_options.git_commit;
pub const dirty: bool = build_options.git_dirty;

/// True when git could not answer at all, which is a supported state: a tarball
/// built from `build.zig.zon`'s `.paths` carries no repository.
pub const known = !std.mem.eql(u8, branch, "unknown");

/// What `scripts/read-provenance` anchors its search on.
///
/// **Changing this changes an interface.** The script greps binaries for this exact
/// text, and the test at the bottom of this file is the only thing tying the two
/// spellings together. Lowercase-with-hyphen matches the `clap.log` message style
/// rather than the shouting a C macro would use, because it is read in the same
/// places those messages are.
pub const marker_prefix = "fosforo-build: ";

/// The line stamped into every binary, and the only provenance a reader can recover
/// from an installed bundle without building anything.
///
/// **Kept live by being logged.** `plugin.init` passes this to `Log.print` as a
/// runtime argument, and `init` is reachable from the factory in every optimize
/// mode, so the bytes cannot be eliminated. That is a claim rather than a proof,
/// which is why CI asserts the marker is present in a built bundle, and asserts it
/// separately for the CMake-built pair: those are `--release=fast` where everything
/// the other job builds is Debug.
///
/// Self-describing `key=value` fields rather than bare positions, so a reader that
/// has only the line still knows what it is holding.
pub const marker: [:0]const u8 = terminate(marker_prefix ++
    "version=" ++ version ++
    " branch=" ++ branch ++
    " commit=" ++ commit ++
    " dirty=" ++ (if (dirty) "yes" else "no"));

/// What the host displays as the plugin's version.
///
/// The version string is free metadata: unlike the CLAP `id` and the AU triple, no
/// host persists it into a project file, so the identifiers section of the build
/// plan leaves it out of the permanence table. That is what makes it the right
/// carrier, and it is also why the base version stays at the front rather than being
/// replaced.
///
/// The branch is sanitised here and left verbatim in `marker`, which is deliberate
/// rather than an oversight: semver build metadata admits only `[0-9A-Za-z-]` and
/// `.`, and a branch name like `chore/add-build-provenance` carries a `/`. The
/// marker has no such grammar and is read by people, so it keeps the real name.
pub const descriptor_version: [:0]const u8 = terminate(if (!known)
    version ++ "+unknown"
else
    version ++ "+" ++ sanitize(branch) ++ "." ++ sanitize(commit) ++ (if (dirty) ".dirty" else ""));

/// Replace anything semver build metadata does not admit.
fn sanitize(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |ch| out = out ++ [_]u8{switch (ch) {
            '0'...'9', 'A'...'Z', 'a'...'z', '-' => ch,
            else => '-',
        }};
        return out;
    }
}

/// Freeze a comptime-built string into a sentinel-terminated one.
///
/// `descriptor.version` crosses the ABI as a C string and `Log.message` takes one,
/// so the sentinel is required rather than tidy. `++` over `[:0]const u8` slices
/// does not carry one through, so it is added once, here.
fn terminate(comptime s: []const u8) [:0]const u8 {
    comptime {
        var buf: [s.len:0]u8 = undefined;
        @memcpy(buf[0..s.len], s);
        buf[s.len] = 0;
        const frozen = buf;
        return &frozen;
    }
}

test "the descriptor version still starts with the declared one" {
    // The point of the suffix is to add provenance to the version, not to replace
    // it. A reader looking for `0.0.0` must still find it at the front, which is
    // also what keeps the string parseable as semver.
    try testing.expect(std.mem.startsWith(u8, descriptor_version, version));
    try testing.expect(descriptor_version.len > version.len);
    try testing.expectEqual(@as(u8, '+'), descriptor_version[version.len]);
}

test "the descriptor version is valid semver build metadata" {
    // Everything after the `+` must be `[0-9A-Za-z-]` or `.`, which is the whole
    // reason `sanitize` exists. A branch with a `/` in it is the ordinary case here,
    // not an edge one: every branch in this repository is named `type/subject`.
    for (descriptor_version[version.len + 1 ..]) |ch| switch (ch) {
        '0'...'9', 'A'...'Z', 'a'...'z', '-', '.' => {},
        else => return error.InvalidBuildMetadata,
    };
}

test "the marker carries every field and starts with its prefix" {
    try testing.expect(std.mem.startsWith(u8, marker, marker_prefix));
    for ([_][]const u8{ "version=", " branch=", " commit=", " dirty=" }) |field| {
        try testing.expect(std.mem.indexOf(u8, marker, field) != null);
    }

    // The dirty field is a closed vocabulary, because the script parses it.
    try testing.expect(std.mem.endsWith(u8, marker, if (dirty) "dirty=yes" else "dirty=no"));
}

test "the marker survives a grep for printable text" {
    // `scripts/read-provenance` extracts this with a bounded run of non-control
    // characters, which stops at the NUL that terminates the literal in the binary.
    // A field holding a newline or a tab would truncate the line silently and the
    // script would report a well-formed prefix of it, which is the failure worth
    // refusing here rather than discovering in a report.
    for (marker) |ch| try testing.expect(ch >= 0x20 and ch != 0x7f);
}

test "sanitize replaces exactly what semver forbids" {
    // `comptime` at each call site rather than on the parameter: this builds its
    // result by concatenation, so it can only ever run at comptime, and a bare call
    // from a test body is a runtime one. The declarations above reach it from const
    // initialisers and so need no marker.
    try testing.expectEqualStrings("chore-add-build-provenance", comptime sanitize("chore/add-build-provenance"));
    try testing.expectEqualStrings("84bd70d", comptime sanitize("84bd70d"));
    try testing.expectEqualStrings("a-b-c", comptime sanitize("a b_c"));

    // Already-legal characters are left alone, including the hyphen, which is the
    // one punctuation mark semver admits and therefore the one a replacement must
    // not disturb.
    try testing.expectEqualStrings("Feature-1", comptime sanitize("Feature-1"));
}

test "the reader script and this module agree on the marker" {
    // `scripts/read-provenance` is the one implementation of reading provenance back
    // out of a built file, and it restates this module's prefix in a third language
    // with nothing linking the two spellings. The failure is quiet: a prefix that
    // moved leaves the script reporting "no provenance" for every bundle, which
    // reads exactly like a bundle predating this change.
    //
    // Same shape as the `measure-trace` test in gpu/metal/renderer.zig, and embedded
    // inside the test for the same reason: `build.zig` registers this import on the
    // test module alone, so no shipping artifact carries a shell script's bytes.
    const script = @embedFile("read-provenance");
    try testing.expect(std.mem.indexOf(u8, script, marker_prefix) != null);
}
