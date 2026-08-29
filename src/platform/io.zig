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
var backend: std.Io.Threaded = .init_single_threaded;

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
