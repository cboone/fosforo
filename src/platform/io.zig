//! The project's one `std.Io` instance.
//!
//! Zig 0.16 moved `Mutex`, every clock, and `sleep` behind an `Io`, and file
//! operations with them. Three of those this project needs and takes from here;
//! `Mutex` it does not, for reasons recorded in ADR 0015 and restated at the two
//! sites that hand-roll what `Io` would otherwise supply (`Gate` in
//! `clap/gui.zig`, the libdispatch semaphore in `gpu/metal/renderer.zig`).
//!
//! The third arrived with #61 and is two things rather than one: `Dir.statFile`
//! and `Dir.readFile`, for the shader a debug build reloads, and
//! `futexWaitTimeout`/`futexWake`, which is how the thread doing that waits out a
//! poll interval it can still be woken from. `std.Thread` in 0.16 has neither a
//! `Futex` nor a `ResetEvent` to reach for instead, so that wait is this ADR
//! being followed rather than an exemption from it.
//!
//! This file exists to hold the construction, not to hide the callers. Reading
//! the clock still lives next to the render loop it paces, and sleeping still
//! lives in the harness that waits, because that is where the reason for each is
//! legible. What must not be spread around is the choice of constructor.

const std = @import("std");

/// **`init_single_threaded`, never `Threaded.init`.**
///
/// `Threaded.init` calls `posix.sigaction` on `SIG.IO` and `SIG.PIPE`. A plugin
/// is loaded into the host's address space, so it would not be installing its
/// own handlers, it would be replacing REAPER's or Logic's. Nothing in the type
/// system stops that, and the symptom would surface in the host rather than
/// here, which is why the constructor is named in exactly one place.
///
/// `init_single_threaded` is a comptime value: it uses no allocator, spawns no
/// threads, installs no handlers, and its `deinit` is documented as unnecessary.
/// The functions reached through it do not touch this value at all. `now`
/// discards its userdata and calls `clock_gettime`; `sleep` reaches `nanosleep`
/// by way of a threadlocal that only a runtime-spawned thread ever sets. That is
/// what makes one shared instance safe to read from the main thread, CoreVideo's
/// callback thread, and the harness alike.
///
/// Named as a `const` so the value can be asserted rather than only the token
/// that produced it; see the `comptime` block below.
const backend_init: std.Io.Threaded = .init_single_threaded;

var backend: std.Io.Threaded = backend_init;

comptime {
    // **The type system already refuses the obvious substitution**, which is
    // worth knowing before deciding what still needs guarding. `Threaded.init`
    // calls `posix.sigaction` and `std.Thread.getCpuCount`, and a container-level
    // initializer must be comptime-evaluable, so writing it here is a compile
    // error rather than a plugin that ships. What it refuses nothing about is the
    // restructure that reaches the same place: `= undefined` plus a `setup`
    // function calling `init` at runtime. The canary below is what covers that.
    //
    // These three pin the *value*, which is the half a canary cannot hold: a
    // global find-and-replace rewrites a canary's string literals along with the
    // code they name, and leaves this standing. A `deinit`-less single-threaded
    // instance is `.nothing` on both limits and has installed no handler.
    //
    // Unlike `std.debug.assert` on a runtime path this survives `--release=fast`,
    // because a failing comptime assert is a compile error in every optimize
    // mode. The field set is `std/Io/Threaded.zig:1674`; read it rather than
    // recalling it if a Zig upgrade moves this (ADR 0002).
    std.debug.assert(!backend_init.have_signal_handler);
    std.debug.assert(backend_init.async_limit == .nothing);
    std.debug.assert(backend_init.concurrent_limit == .nothing);
}

/// The instance every caller shares.
///
/// Costs nothing, measured rather than assumed. Adopting this for the render
/// meter's clock moved a debug `.clap` by -128 bytes and added no symbol, because
/// `std.debug.print` in `clap/log.zig` already links the whole of `Io/Threaded`
/// into every debug build. A release build strips all of it, along with the
/// debug-only caller that wanted the clock.
pub fn get() std.Io {
    return backend.io();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const canary = @import("../canary.zig");

// The canary.
//
// `AGENTS.md` lists the constructor rule among the non-negotiables and until now
// nothing enforced it. This file had zero tests, and the cost of a silent edit is
// not local: `Threaded.init` calls `posix.sigaction` on `SIG.IO` and `SIG.PIPE`,
// and a plugin lives in the host's address space, so it would replace REAPER's or
// Logic's handlers rather than install its own (ADR 0015).
//
// **This and the `comptime` block above are complementary rather than belt and
// braces.** That one pins the value and survives a find-and-replace; it cannot
// see a restructure, because a file that stopped naming `backend_init` would take
// the assertions with it. This one pins the shape and cannot see a value, because
// a differently-named constant with the same spelling would satisfy it. Between
// them the only route left is deliberate.
//
// It reads the source as text and proves nothing about behaviour, which is what
// the name says out loud (ADR 0016).
test "the constructor is still the single-threaded one, and nothing here reaches Threaded.init" {
    const code = canary.implementation(@embedFile("io.zig"));

    try testing.expectEqual(1, canary.stated(code, "const backend_init: std.Io.Threaded = .init_single_threaded;"));
    try testing.expectEqual(1, canary.stated(code, "var backend: std.Io.Threaded = backend_init;"));

    // The restructure, which is the only shape the compiler does not already
    // refuse. This assertion is possible only because comments are not statement
    // lines: the docstrings above name `Threaded.init` twice in order to forbid
    // it, and a canary that counted raw text could not tell those from a call.
    //
    // It pins one spelling. Writing the constant fully qualified, as
    // `std.Io.Threaded.init_single_threaded`, would trip this; that is the
    // canary's contract rather than a false positive.
    try testing.expectEqual(0, canary.mentions(code, "Threaded.init"));

    // And that there is one instance rather than two, so a second backend cannot
    // arrive beside the first with a constructor of its own. Two lines, the
    // declaration and the var it initializes.
    try testing.expectEqual(2, canary.mentions(code, "std.Io.Threaded"));
}

test "the instance every caller shares is the one that was checked, and nothing reassigns it" {
    const code = canary.implementation(@embedFile("io.zig"));

    // `get` handing back something built elsewhere would leave both guards above
    // asserting about a value nothing reads.
    try testing.expectEqual(1, canary.stated(code, "return backend.io();"));

    // The restructure, from the other side. `= undefined` plus a `setup` that
    // calls `init` at runtime is the one route the compiler leaves open, and it
    // has to assign `backend` somewhere to be worth writing. The declaration
    // itself does not match, because it reads `backend:` before its `=`.
    try testing.expectEqual(0, canary.mentions(code, "backend ="));
}
