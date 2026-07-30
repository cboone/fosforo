# The CVDisplayLink render loop and the resize seam

Addresses [issue #5](https://github.com/cboone/fosforo/issues/5), phase 1 of [the build plan](2026-07-25-repo-foundation-and-phased-build-plan.md).

## Context

Issue #4 landed an editor that draws. It draws exactly twice: once from `show`, and once from `set_parent` when the host had already shown the window. After that the picture is frozen, which is invisible today only because the picture is a flat colour. Phase 2's trace and phase 3's decay both need a frame every vsync, and neither can be built on a render path that only runs when the host calls a lifecycle callback.

This change gives the plugin its render thread. A `CVDisplayLink` tied to the display the view is on calls `Editor.tick` at the display's refresh rate, and `Renderer.frame` moves off the main thread for good.

Introducing a second thread that touches the renderer is the whole reason this issue also owns resizing. The editor is currently fixed at 960x540 and reports `can_resize` as false, because the GUI resize callback arrives on the host's **main thread** and has to reallocate resources the **render thread** is actively using. [ADR 0010](../../adr/0010-lock-free-history-buffer.md) settles the shape of the answer: a pending-resize mailbox that the render thread services at the top of its next tick, before it touches the old resources. The two land together or not at all, which is what issue #4's plan committed to and why `src/clap/gui.zig:30` and `src/clap/plugin.zig:532` both carry a comment pointing here.

Getting this wrong produces a use-after-free that only appears when a user drags the window during playback. Building the mailbox now, while the only resource behind the seam is a drawable that is cheap to get wrong, is much easier than retrofitting it in phase 3 when the accumulation textures make the same bug fatal.

## Decisions already made

| Question                            | Decision                                                                                                                             |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Display link API                    | `CVDisplayLink`. Deprecated in macOS 15 but the only option at the project's 11.0 deployment target, and Zig declares the externs    |
| Where the display link lives        | `src/platform/displaylink.zig`, CoreVideo only. It names no Metal type and no AppKit type, and takes a comptime callback             |
| Where the mailbox lives             | `src/clap/gui.zig`, above the seam. It is pure atomics with no platform dependency, which is what makes it properly testable         |
| What the render thread may mutate   | The `CAMetalLayer`'s drawable configuration, which is Metal. The layer's `frame` stays on the main thread, which is AppKit geometry  |
| Frames in flight                    | A `dispatch_semaphore` of 3, signalled from an `addCompletedHandler:` block, plus `maximumDrawableCount` of 3                        |
| How the block captures the semaphore | As an `objc.c.id`, so the block retains it. That is what makes `deinit` safe while a command buffer is still executing              |
| Resize notifications                | A runtime `NSView` subclass overriding `setFrameSize:`, `viewDidChangeBackingProperties`, and `viewDidMoveToWindow`                  |
| Resize bounds                       | Free on both axes, `preserve_aspect_ratio` false, clamped to a 480x270 minimum. No maximum                                          |
| The 16:9 default                    | Stays 960x540 but is **not** enforced. The rationale for it is that a time axis wants room, which argues against locking the ratio   |
| What tests may touch                | Unchanged: no test creates a view, a display link, or a Metal device. The mailbox and the size arithmetic are exercised directly     |

## Changes

### `src/platform/displaylink.zig` (new): CoreVideo, and nothing else

Six `extern "c"` declarations and a struct. No AppKit, no Metal, no import of anything above it.

```zig
pub const DisplayID = u32;

pub const DisplayLink = struct {
    link: *anyopaque,

    pub fn create(display: DisplayID, comptime tick: fn (*anyopaque) void, context: *anyopaque) ?DisplayLink
    pub fn start(self: DisplayLink) bool
    pub fn stop(self: DisplayLink) void
    pub fn setDisplay(self: DisplayLink, display: DisplayID) void
    pub fn destroy(self: DisplayLink) void   // stop, then release
};
```

`tick` is a **comptime** parameter so the trampoline that adapts CoreVideo's six-argument callback down to `tick(context)` is generated at compile time. CoreVideo carries one `void*`, and taking the callback at comptime is what lets that one pointer be the caller's context rather than half of a pair the caller would otherwise have to allocate somewhere stable.

The callback's two `CVTimeStamp *` parameters are declared `?*const anyopaque`. Every parameter is pointer-sized, so this is ABI-identical to the real signature, and restating an 80-byte struct with a nested `CVSMPTETime` that nothing reads would be carrying risk for no caller. Phase 3's frame-rate-independent decay is the first thing that wants the timestamps and can restate them then, which is the same rule `src/gpu/iface.zig:11` already applies to the seam.

`create` uses `CVDisplayLinkCreateWithCGDisplay`, and the callback must return `kCVReturnSuccess` or CoreVideo stops calling it.

### `src/platform/view.zig`: a runtime `NSView` subclass

The file's docstring currently says issue #5 registers a subclass when it has a reason to. It now has three.

**The class is registered once per loaded copy of the plugin**, through `std.once`, and is never disposed: `objc_disposeClassPair` is illegal while instances exist, and the class is process-lifetime by nature.

**The name carries an address-derived suffix.** `objc_allocateClassPair` returns nil when the name is taken, so two copies of this plugin in one process, which is exactly what happens when the CLAP and the clap-wrapper AU are both loaded, would leave the second copy with no view class at all. The suffix is the hex of `@intFromPtr(&class_seed)` where `class_seed` is a module-local `var`, so each loaded image gets its own. Reusing the existing class instead would be worse than failing: its method IMPs point into the *other* copy's `__TEXT`, and they dangle the moment that copy unloads.

**One ivar** holds a `*const Delegate`. `zig-objc`'s `addIvar` only offers `id`-typed ivars, which is a pointer-sized slot with a `@` encoding. That is safe for a non-object pointer here because a class built with `objc_allocateClassPair` has a null strong-ivar layout, so `objc_destructInstance` releases nothing.

The delegate is how the view reports upward without knowing what is above it:

```zig
pub const Delegate = struct {
    context: *anyopaque,
    /// [main-thread] The view's size in logical points changed.
    resized: *const fn (context: *anyopaque, width: u32, height: u32) void,
    /// [main-thread] The backing scale factor or the display changed.
    displayChanged: *const fn (context: *anyopaque) void,
};
```

Three overrides, each calling `super` first through `msgSendSuper`:

| Selector                         | Why it is needed                                                                                     |
| -------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `setFrameSize:`                  | The single funnel for a size change, whether it came from CLAP's `set_size` or from the host resizing the parent and letting the autoresizing mask carry it |
| `viewDidChangeBackingProperties` | A window dragged between a Retina and a non-Retina display. Without it the drawable keeps the old scale, which issue #4's plan explicitly deferred to here |
| `viewDidMoveToWindow`            | The window may now be on a different display, so the display link has to be retargeted or it keeps pacing to the old one's refresh rate |

`setFrameSize:` also sets `[[self layer] setFrame:]`. That is a `CALayer` message and names no Metal type, so it is not the leak ADR 0005 forbids; it is geometry that belongs to the view hierarchy. It is insurance: AppKit may already track the layer's frame for a layer-hosting view, and setting it twice is harmless while not setting it at all is a layer that does not follow its view.

Two new methods:

- `displayID(self) DisplayID`, reading `[[[[self window] screen] deviceDescription] objectForKey:@"NSScreenNumber"]` and falling back to `CGMainDisplayID()`. Same shape as the existing `backingScale` fallback chain at `src/platform/view.zig:88`, and reachable for the same reason: a view has no window until it is in one.
- `setSize(self, width, height)`, sending `setFrameSize:` so the override runs and the notification path is the same one the host's own resize takes.

### `src/gpu/iface.zig`: one more operation on the seam

```zig
comptime {
    assertSignature("init", @TypeOf(Renderer.init), fn (NativeView, Size, f64, *Diagnostics) Error!Renderer);
    assertSignature("deinit", @TypeOf(Renderer.deinit), fn (*Renderer) void);
    assertSignature("resize", @TypeOf(Renderer.resize), fn (*Renderer, Size, f64) void);
    assertSignature("frame", @TypeOf(Renderer.frame), fn (*Renderer) void);
}
```

`resize` is documented `[render-thread]`: it is called only from the tick, only after the mailbox has been drained, and never from the main thread. The file's note that there is deliberately no `resize` yet is replaced by the reason there is one now.

### `src/gpu/metal/renderer.zig`: frames in flight and a resizable surface

**One new owned object**, a `dispatch_semaphore` created with a value of 3, alongside `layer.maximumDrawableCount = 3`. The two bound different things, which is why both are set: the drawable pool bounds presented frames, and the semaphore bounds how far the CPU may run ahead of the GPU, which is what phase 2's per-frame dynamic buffers will actually need.

```zig
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sema: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sema: *anyopaque) isize;
```

**The completion block captures the semaphore as an `objc.c.id`.** `zig-objc`'s `Block` retains `id`-typed captures when the runtime copies the block to the heap, which `addCompletedHandler:` does. That is not a detail: it is what makes `deinit` safe. Releasing the semaphore while a command buffer is still executing would otherwise leave a queued handler signalling freed memory, and the alternative fix, draining all three slots before releasing, can hang the host's main thread on a wedged GPU.

`frame()` gains a slot acquisition at the top and a hand-off at the bottom:

```zig
_ = dispatch_semaphore_wait(self.in_flight, forever);

// Every early return below has to give the slot back. Three skipped frames in
// a row would otherwise drain the semaphore and stop the render loop for good,
// which is the classic way this pattern fails.
var handed_off = false;
defer if (!handed_off) _ = dispatch_semaphore_signal(self.in_flight);

// ... the existing nil checks on nextDrawable, commandBuffer, and the encoder,
//     all of which now return through that defer ...

buffer.msgSend(void, "addCompletedHandler:", .{&done});
handed_off = true;
buffer.msgSend(void, "presentDrawable:", .{drawable});
buffer.msgSend(void, "commit", .{});
```

**`resize(self, size, scale)`** sets `contentsScale` and `drawableSize` from the mailbox's values. It is the render thread's half of the resize, and phase 3's accumulation textures are reallocated here, before anything reads the old ones.

**`frame` and `resize` assert they are not on the main thread**, using a new `platform.assertNotMainThread()` that mirrors the existing `assertMainThread`. This is ADR 0010's "the render thread touches Metal only" written as something checkable. It is only sound because `drawOnce` goes away in this change: after it, nothing on the main thread calls `frame`.

### `src/clap/gui.zig`: the mailbox, and the loop that drains it

**`Pending`**, the single-slot mailbox, packed into one `u64` so a post is one atomic store and a drain is one atomic swap:

```zig
const Packed = packed struct(u64) {
    width: u16,
    height: u16,
    /// Backing pixels per point in 1/256ths. Exact for the 1.0 and 2.0 that
    /// AppKit actually reports, and within a quarter of a percent otherwise.
    scale_256: u16,
    _: u16 = 0,
};
```

All-zero is the empty state, which needs no separate flag: Metal rejects a zero-sized drawable, so a zero post carries nothing and is correctly indistinguishable from no post at all. `post` stores with release ordering and last write wins, which is the right semantics for a drag producing one post per frame. `take` swaps in the empty value with acquire ordering, so a size is drained exactly once.

**`Editor`** gains the loop's state:

```zig
current: gpu.Size = default_size,
scale: f64 = 1.0,

link: ?display_link.DisplayLink = null,
pending: Pending = .{},
delegate: view_mod.Delegate = undefined,

/// Held for the body of a tick, and taken once by `destroy` as a barrier.
tick_lock: std.Thread.Mutex = .{},
running: std.atomic.Value(bool) = .init(false),
```

`tick`, the render thread's entry point:

```zig
fn tick(self: *Editor) void {
    if (!self.running.load(.acquire)) return;

    self.tick_lock.lock();
    defer self.tick_lock.unlock();

    const renderer = if (self.renderer) |*r| r else return;
    if (self.pending.take()) |update| renderer.resize(update.size, update.scale);
    renderer.frame();
}
```

`destroy` closes the race that lock exists for:

```zig
self.running.store(false, .release);       // an in-flight tick may still be running
if (self.link) |l| l.destroy();            // no new tick will start
self.link = null;

// CVDisplayLinkStop is not documented to wait for a callback already in
// flight, and both WebKit and Chromium guard it rather than assume. Taking the
// lock once is that guarantee: it cannot be acquired until the tick releases
// it, and the flag above means the next tick returns before touching anything.
self.tick_lock.lock();
self.tick_lock.unlock();

// ... the existing renderer-then-view teardown, unchanged ...
```

The `running` flag is what keeps that barrier cheap. Without it the main thread could wait on a tick blocked in `nextDrawable`, which has a one-second timeout; with it, the tick that beat the flag is the only one that can be inside the lock, and every tick after it returns immediately.

The rest:

- `setParent` builds the view with a delegate pointing at itself, then the renderer, then the display link over `view.displayID()`, and starts it when already visible.
- `setHidden` starts and stops the link rather than drawing once. A hidden editor costing no GPU is what keeps several open instances honest.
- `setSize(width, height)` clamps to `min_size` and calls `view.setSize`, which runs the `setFrameSize:` override synchronously and posts through the same path the host's own resize takes. One funnel, no duplicated posting.
- `adjustSize(width, height)` clamps each axis independently, so 300x900 answers 480x900 rather than 480x270.
- `size()` returns `current` instead of the constant.
- `onResized` and `onDisplayChanged` are the delegate implementations. The second re-reads `backingScale`, posts, and retargets the link with `setDisplay`.
- `drawOnce` is deleted.

**`log: ?*const log.Log`**, wired from `Instance.init`. In debug builds the tick reports observed frames per second and the current drawable size once a second. That line is the only way to answer the issue's first verification bullet from inside a host: the deliverable is a flat colour, so a loop running at 120 Hz and a loop that has stopped look identical.

### `src/clap/plugin.zig`: advertise a resizable editor

| Callback           | Change                                                                                              |
| ------------------ | ----------------------------------------------------------------------------------------------------- |
| `can_resize`       | Now true. The comment pointing at issue #5 comes out                                                 |
| `get_resize_hints` | Fills the struct: both axes true, `preserve_aspect_ratio` false, and returns true                    |
| `adjust_size`      | Delegates to `Editor.adjustSize` rather than answering with the fixed size                           |
| `set_size`         | Delegates to `Editor.setSize` rather than comparing against the only size there was                  |
| `get_size`         | Unchanged in shape, but `Editor.size()` beneath it is now the current size rather than the constant  |

`Instance.init` gains `self.editor.log = &self.log;`. `&self.log` is stable because `Instance` is heap-allocated and lives exactly as long as the editor inside it.

### `src/main.zig` and the docs

`src/main.zig`'s test block names `platform/displaylink.zig` so its tests are collected.

`AGENTS.md` gains `platform/displaylink.zig` in the structure map, and four gotchas: that `CVDisplayLink` is deprecated in macOS 15 and kept anyway; that the runtime view class name must be unique per loaded image; that every early return in `frame` has to hand its semaphore slot back; and that the render thread may set the layer's drawable configuration but not its frame.

`CHANGELOG.md` gains an Added entry. The build plan's phase 3 step 8, "Resize mailbox", is marked as having landed early in phase 1, since it did.

## Tests

The rule from issue #4 holds without exception: **no test creates an `NSView`, a display link, or a Metal device.** What this change adds is mostly pure, which is why the mailbox went above the seam rather than into the backend.

| Area           | Cases                                                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| mailbox        | Post then take round trips; take on an empty mailbox is null; take twice yields null the second time; the last of several posts wins |
| mailbox        | A zero width or height is not distinguishable from empty and is ignored; a size beyond `u16` saturates rather than wrapping     |
| mailbox        | Scale quantisation is exact at 1.0, 2.0, and 3.0, and round trips within 1/256 elsewhere                                        |
| sizing         | `setSize` clamps each axis independently against `min_size`; `adjustSize` answers the clamped size; `size()` follows `setSize`  |
| sizing         | `get_size` reports the size a preceding `set_size` applied, rather than the default                                            |
| hints          | `can_resize` is true and `get_resize_hints` fills both axes with `preserve_aspect_ratio` false                                  |
| lifecycle      | `setHidden` and `destroy` are still reachable and idempotent with a null link, which is the state every test is in              |
| seam           | The comptime signature assertion covers `resize`, so a backend that took an `objc.Object` stops compiling                       |

Two existing tests assert the state this change ends and are rewritten rather than extended: `src/clap/plugin.zig:983`, "the editor is a fixed size that set_size will only confirm", and the `can_resize` expectation inside it.

## Verification

```bash
zig fmt --check build.zig src/
zig build test
zig build
zig build validate-shaders
clap-validator validate zig-out/Fosforo.clap
git ls-files -z | xargs -0 shfmt -f | xargs shfmt -d
```

`clap-validator` matters more here than it did for issue #4: `can_resize` being true is an invitation for a host to call `adjust_size` and `set_size`, so the passing count should hold rather than regress.

Then the parts only a host can answer:

```bash
zig build install-clap
```

In REAPER, launched from a terminal so the debug frame-rate line is readable:

1. Open the editor. The once-a-second line must report a rate matching the display's refresh rate, not zero and not a number that decays.
1. Drag the window edge continuously for thirty seconds with audio playing. The reported drawable size must track the drag, the picture must stay flat dim grey with no flicker or black frames, and audio must not glitch.
1. Drag the window between two displays with different refresh rates and different backing scales. The reported rate must change to match the new display, and the reported drawable size must change with the scale.
1. Open four instances at once, all visible, all playing. Watch for dropouts.
1. Close and reopen the editor twenty times, then close the project with the editor open and audio playing.

The teardown race is the one this cannot prove by observation, so it gets the tool that can:

```bash
zig build -Doptimize=Debug
# then, with the editor open and being resized:
leaks --atExit -- "$(pgrep -x REAPER)"
```

A tick that outlived its renderer shows as a crash inside `objc_msgSend` rather than as a leak, so the twenty open-close cycles under a debug build with the main-thread assertions live are the real check. Run at least one of those cycles while dragging the window, since that is the interleaving the mailbox exists for.

Then Logic:

```bash
cmake -B build cmake/ && cmake --build build --target fosforo_all
auval -v aufx Fsfr Ctmn
```

`auval` remains unverified on this machine for reasons that predate this work and are recorded in [issue #4's plan](../done/2026-07-29-clap-gui-extension-and-metal-view.md). Opening the editor in Logic by hand and resizing it is still worth doing.

## Commits

Small commits at each logical boundary, all referencing `(#5)`:

1. `feat: wrap CVDisplayLink behind a platform type (#5)`
1. `feat: carry a pending resize from the main thread to the render thread (#5)`
1. `feat: bound frames in flight and resize the drawable behind the seam (#5)`
1. `feat: report resizes and display changes from the view (#5)`
1. `feat: drive rendering from the display link and advertise a resizable editor (#5)`
1. `docs: record the display link, the mailbox, and the runtime view subclass (#5)`

## Out of scope

Recorded so these read as deliberate omissions:

- The ring of per-frame dynamic buffers the semaphore exists to protect. There is nothing dynamic to buffer until phase 2's history buffer, and the semaphore is what that phase will find already in place.
- Reading the `CVTimeStamp`s. Phase 3's frame-rate-independent decay is the first caller, and it is the phase that should decide how time is measured.
- The accumulation texture, decay, and the tonemap. Phase 3, and the reason `Renderer.resize` exists in the shape it does.
- `clap_host_gui.request_resize`. Nothing here needs to ask the host to change the editor's size; every resize in this change originates with the host or the user.
- Mouse input and the tracking areas it needs, even though a subclass now exists to hang them on. That is phase 5.
- A maximum editor size. Neither CLAP's resize hints nor any host observed asks for one, and Metal refusing an absurd drawable is a better failure than a number invented here.

## Risks

| Risk                                                                              | Mitigation                                                                                                                                          |
| --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CVDisplayLink` is deprecated as of macOS 15                                      | Still the only option at the 11.0 deployment target, and Zig declares the externs itself so nothing warns. Revisit with the ADR that raises the target |
| `CVDisplayLinkStop` is not documented to wait for a callback already in flight    | The `tick_lock` barrier in `destroy` makes the question moot rather than betting on the answer                                                        |
| A skipped frame leaks its semaphore slot and stalls the loop after three          | One `defer` covering every early return, and the hand-off is the last thing `frame` does before committing                                            |
| The completion block outlives the renderer                                        | The semaphore is captured as an `objc.c.id`, so the block retains it and `deinit` releasing is not the last reference                                 |
| Two copies of the plugin in one process collide on the runtime class name         | An address-derived suffix per loaded image. Reusing the existing class would leave IMPs pointing into another copy's text segment                     |
| AppKit may not track a layer-hosting view's layer frame                           | `setFrameSize:` sets it explicitly. Redundant if AppKit does it, load-bearing if it does not, and one message either way                              |
| The render thread mutating `CAMetalLayer` properties off the main thread          | Only `contentsScale` and `drawableSize`, which are the drawable's Metal configuration. `frame` and the view hierarchy stay on the main thread         |
| A `@`-encoded ivar holding a pointer that is not an object                        | A class from `objc_allocateClassPair` has a null strong-ivar layout, so `objc_destructInstance` releases nothing                                      |
| `zig build test` picking up a dependency on a GPU or a window server              | Unchanged rule, and the mailbox went above the seam precisely so the new logic is testable without either                                             |
