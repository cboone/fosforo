# Stereo audio ports, pass-through process, and state

Addresses [issue #3](https://github.com/cboone/fosforo/issues/3), phase 1 of [the build plan](2026-07-25-repo-foundation-and-phased-build-plan.md).

## Context

Issue #2 landed a plugin that instantiates: the factory hands out a descriptor, and an instance walks its whole lifecycle. What it does not do is carry audio. `getExtension` returns null for everything, so a host sees a plugin with no ports, routes nothing through it, and `process` has nothing to copy. `clap-validator` cannot exercise its render or state suites against a plugin in that shape, and REAPER shows the plugin as present but inert.

This change adds the plumbing that makes it a real audio effect while it still does no analysis. Four extensions, in the order they matter:

- `clap.audio-ports` gives the host somewhere to route signal.
- `process` copies input to output, so inserting the plugin on a track is transparent.
- `clap.state` writes a versioned header now, so a project saved against this build still loads once there is real state to persist.
- `clap.log` routes diagnostics through the host, because `stderr` is invisible inside most DAWs.

The signal tap, the history buffer, and anything that draws arrive in phase 2. The one forward-looking piece here is the real-time safety seam from ADR 0010: the DSP path takes an allocator parameter, fed by a fixed-buffer allocator sized at `activate`, so "does the audio path touch the heap" is a fact about the call graph rather than a convention.

## Decisions already made

| Question                    | Decision                                                                                                                |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Where the new code lives    | `state.zig` and `log.zig` split out; the audio-ports vtable and `process` stay in `plugin.zig` as glue over `*Instance` |
| The ADR 0010 allocator seam | Built now, over a zero-length scratch slice, so any allocation fails rather than reaching the heap                      |
| State header shape          | 4-byte magic `"FSFR"` plus a little-endian `u32` version, 8 bytes total                                                 |
| Unrecognized trailing bytes | Tolerated on load, so a future build's payload does not make the file unreadable by this one                            |

## Changes

### `src/clap/c.zig`: layout assertions for the new ABI structs

Every struct crossing the ABI gets `assertLayout` coverage in the existing `comptime` block, matching the pattern already there. A field-count change is how a CLAP bump announces itself, and a wrong offset is a crash inside someone else's DAW rather than a compile error.

Add assertions for `clap_plugin_audio_ports_t` (2 fields), `clap_audio_port_info_t` (6), `clap_audio_buffer_t` (5), `clap_process_t` (9), `clap_plugin_state_t` (2), `clap_istream_t` (2), `clap_ostream_t` (2), and `clap_host_log_t` (1).

Nothing needs restating here. ADR 0004 records that all 38 extension id strings survive preprocessing as statics, and that `CLAP_NAME_SIZE` and `CLAP_INVALID_ID` resolve to concrete values. `CLAP_PORT_STEREO` is a `static const char[]` like `CLAP_PLUGIN_FACTORY_ID`, which `src/main.zig:34` already compares against directly, so the same `std.mem.eql(u8, std.mem.span(id), &c.CLAP_EXT_…)` spelling works for extension dispatch. The `CLAP_AUDIO_PORT_*` and `CLAP_LOG_*` constants are enum members and translate normally.

### `src/clap/log.zig` (new): diagnostics through the host

A small wrapper looked up once, at `init`, where host extensions are reachable.

```zig
pub const Log = struct {
    ext: ?*const c.clap_host_log_t = null,

    pub fn init(host: *const c.clap_host_t) Log
    pub fn message(self: Log, severity: c.clap_log_severity, msg: [*:0]const u8) void
    pub fn print(self: Log, severity: c.clap_log_severity, comptime fmt: []const u8, args: anytype) void
};
```

`print` formats into a fixed stack buffer with `std.fmt.bufPrintZ` and truncates rather than failing, so a long message degrades instead of disappearing. No heap, by construction.

When the host does not offer `clap.log`, fall back to `std.debug.print` in debug builds and no-op in release. Document that this makes `Log` main-thread-only for now: `clap_host_log.log` itself is `[thread-safe]`, but the fallback locks stderr and makes a syscall, so nothing on the audio path may reach it (ADR 0010).

### `src/clap/state.zig` (new): the versioned header and the stream loops

Self-contained and testable without an `Instance`, which is why it is a separate file.

```text
offset  size  field
0       4     magic    "FSFR"
4       4     version  u32 little-endian, currently 1
```

The magic reuses the four bytes of the permanent AU subtype code (`aufx`/`Fsfr`/`Ctmn` in `cmake/CMakeLists.txt`), so there is one fewer arbitrary constant to justify. Nothing parses it as an AU code. The version is written little-endian explicitly rather than by memory layout, so the format does not silently depend on ADR 0001 holding forever.

`save` writes exactly those 8 bytes. `load` reads them and returns false on a wrong magic or a version from the future, and otherwise succeeds, ignoring anything after the header. Growth happens by appending fields; the version bump is reserved for the cases that genuinely break old readers.

Both directions need loops, because the host is free to satisfy a read or write partially. Two details worth getting right the first time:

- On the write side, a return of `0` is not documented as meaningful. Treating only negative values as errors would spin forever against a host that returns `0`, so treat anything `<= 0` as a failure.
- On the read side, `0` is end-of-file and `-1` is an I/O error. Both are failures when the header is incomplete, but they are distinct enough that the caller gets a different log line for a truncated file than for a broken stream.

### `src/clap/plugin.zig`: ports, pass-through, and the two new vtables

**`Instance` gains two fields.** A `Log`, set in `init`. And `scratch: []u8`, allocated in `activate` and freed in `deactivate`, which are the only points where allocation is legal because `sample_rate` and `max_frames` are fixed between them.

Size it through a named function so phase 2 changes one expression:

```zig
/// Bytes the audio path may allocate from during one `process` call. Currently
/// zero: a pass-through allocates nothing, so a zero-length fixed buffer turns
/// any allocation into `error.OutOfMemory` instead of a heap call. Phase 2 sizes
/// this from `max_frames` when the history buffer lands.
fn scratchBytes(max_frames: u32) usize {
    _ = max_frames;
    return 0;
}
```

**`process`** asserts the lifecycle as it already does, adds `std.debug.assert(ctx.frames_count <= self.max_frames)` since that is a host contract worth trapping, builds a `std.heap.FixedBufferAllocator` over `self.scratch`, and hands its allocator to a `passThrough` free function. After the call, `std.debug.assert(fba.end_index == 0)` in debug builds. Return `CLAP_PROCESS_CONTINUE` rather than `SLEEP`: an analyzer wants to keep being called.

`passThrough` handles the degenerate cases in a way that cannot put garbage on the bus:

- Null `audio_inputs` or `audio_outputs`, a zero bus count, or a null `data32` means the input is unusable. Clear the output to silence rather than leaving the host's buffer untouched, and set `constant_mask` accordingly.
- Copy `@min(in.channel_count, out.channel_count)` channels, skipping any channel where `in.data32[ch] == out.data32[ch]`, which is the host taking the in-place offer.
- Silence any output channel beyond the input's channel count.
- Propagate `constant_mask`: inherit the input's bit for copied channels, set it for silenced ones. Silence is constant, and a full copy preserves the "buffer is filled with the constant value" guarantee the header requires.

Only 32-bit support is declared, so `data64` is never the populated pointer. A null `data32` is treated as unusable rather than as a cue to look at `data64`.

**The audio-ports vtable** reports one port on each side. Both take id `0`, which the header explicitly permits to overlap across input and output, and `in_place_pair` is set to `0` on both to declare in-place support. Flags are `CLAP_AUDIO_PORT_IS_MAIN`, channel count is 2, and `port_type` points at `c.CLAP_PORT_STEREO`.

Zero the whole `clap_audio_port_info_t` with `std.mem.zeroes` before filling it, then copy the display name (`"Main In"` / `"Main Out"`) into the `[CLAP_NAME_SIZE]u8` field through a bounded helper that always leaves room for the terminator. `get` returns false for any index other than `0`, and for a null `info`.

**The state vtable** is two thin callbacks over `state.zig`, both `[main-thread]`, both logging a warning through `Log` when they fail.

**`getExtension`** dispatches on `clap.audio-ports` and `clap.state` and still returns null for everything else, including `clap.gui` until issue #4.

**`init`** sets `self.log` and emits one `CLAP_LOG_DEBUG` line, which is also the cheapest end-to-end proof that the log path works inside a real host.

### Test fixtures in `src/clap/plugin.zig`

Two existing comments become false with this change and have to be rewritten, not just extended:

- The `test_host` comment at `src/clap/plugin.zig:252` argues that null host function pointers are a deliberate contract check. That stops being true the moment `init` calls `get_extension`. The fixture needs a `get_extension` that returns null, and the comment should say why the remaining pointers stay null.
- The `test_process` comment at `src/clap/plugin.zig:305` says zero audio buses "is the current truth". It no longer is. The fixture needs real stereo input and output buffers with both counts at 1.

Add a second host fixture whose `get_extension` returns a `clap_host_log_t` stub recording into a file-scope buffer, so the log path is covered in both directions. Zig runs the tests in one binary sequentially, so a file-scope capture buffer is safe here.

### Tests to add

| Area        | Cases                                                                                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| audio-ports | `count` is 1 on both sides; `get(0, …)` fills every field including the name and `in_place_pair`; `get(1, …)` returns false                                              |
| process     | stereo copy; in-place (identical pointers) leaves data correct and copies nothing; null input clears the output; mismatched channel counts; `constant_mask` propagation  |
| state       | round trip; a stream that moves one byte per call in each direction; a write error mid-header; a truncated header; wrong magic; a future version; trailing bytes ignored |
| extensions  | `get_extension` returns the audio-ports and state vtables, and still null for `clap.gui`                                                                                 |
| log         | a host offering `clap.log` receives the message; a host without it does not crash                                                                                        |

`src/main.zig`'s test block references modules explicitly (`_ = clap; _ = plugin;`). Add `_ = @import("clap/state.zig");` and `_ = @import("clap/log.zig");` so their tests are collected.

### `AGENTS.md`

Add `clap/state.zig` and `clap/log.zig` to the structure map, alongside the existing `clap/plugin.zig` line. `CLAUDE.md` is a symlink and needs no edit.

## Verification

```bash
zig fmt --check build.zig src/
zig build test
zig build
clap-validator validate zig-out/Fosforo.clap
```

`clap-validator` is installed at `~/.cargo/bin/clap-validator`. Before this change it reports 3 passing tests; afterwards its audio-ports, state round-trip, and process suites should all run and pass. Confirm specifically that the state tests exercise save then load then save and compare, and that `process` survives the buffer-shape variations the validator throws at it.

Then the null test the issue asks for, which is manual:

```bash
zig build install-clap
```

In REAPER, put the same audio on two tracks, insert Fósforo on one, invert the polarity of the other, and sum them. The result must be digital silence. Anything else means `process` is altering the signal.

The AUv2 path is unchanged by this work but is cheap to confirm once:

```bash
cmake -B build cmake/ && cmake --build build --target fosforo_all
auval -v aufx Fsfr Ctmn
```

## Commits

Small commits at each logical boundary, all referencing `(#3)`:

1. `feat: assert the layout of the audio, state, and log ABI structs (#3)`
1. `feat: route diagnostics through the host log extension (#3)`
1. `feat: declare one stereo input and one stereo output (#3)`
1. `feat: pass audio through behind a fixed-buffer allocator (#3)`
1. `feat: save and load a versioned state header (#3)`
1. `docs: list the new modules in the structure map (#3)`

## Out of scope

Recorded so these read as deliberate omissions:

- The signal tap and the lock-free history buffer, which are phase 2. This change builds the allocator seam they will use, and nothing else.
- `clap.gui` and the `NSView` hosting a `CAMetalLayer`, which are issue #4.
- `clap.params`, `clap.latency`, and `clap.tail`. The plugin has no parameters, adds no latency, and has no tail.
- Wiring `clap-validator` into CI. Worth doing, but it is a separate change and not what this issue asks for.
