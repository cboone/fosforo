# The CLAP GUI extension and a Cocoa view hosting a Metal layer

Addresses [issue #4](https://github.com/cboone/fosforo/issues/4), phase 1 of [the build plan](2026-07-25-repo-foundation-and-phased-build-plan.md).

## Context

Issue #3 landed a plugin that carries audio: it declares stereo ports, passes signal through untouched, saves a versioned state header, and logs through the host. What it cannot do is show itself. `getExtension` returns null for `clap.gui`, so REAPER and Logic both open it as a generic parameter strip over a plugin with no parameters, and nothing in the project has yet proven that Zig can reach AppKit and Metal inside someone else's process.

This is the change that proves it. It is the first time the whole chain runs end to end: a CLAP host asks for an extension, gets a vtable of `callconv(.c)` callbacks, hands over an `NSView` through a C union, and receives a `CAMetalLayer` presenting a frame drawn by a shader that was compiled from a string at runtime. Phase 1 exists to get that chain working once so it never has to be debugged again, which is why the deliverable is a dim cleared drawable rather than anything that looks like an oscilloscope.

Three structural pieces arrive with it and outlive it. The renderer seam at `src/gpu/iface.zig` is defined before any Metal is written behind it, which is what [ADR 0005](../../adr/0005-metal-behind-a-renderer-seam.md) asks for. The runtime shader compilation path from [ADR 0009](../../adr/0009-runtime-shader-compilation.md) becomes real rather than hypothetical. And the Objective-C glue from [ADR 0008](../../adr/0008-objective-c-glue-via-zig-objc.md) gets its first caller, since `zig-objc` is currently a dependency nothing imports.

**Scope boundary with [issue #5](https://github.com/cboone/fosforo/issues/5).** That issue owns the `CVDisplayLink` render loop and the resize seam, and the two are deliberately one unit: a resize callback arriving on the main thread has to reallocate resources a render thread is using, and the pending-resize mailbox that makes it safe only makes sense once a render thread exists. So this issue reports `can_resize` as **false** and implements no resize path at all. Nothing written here has to be deleted and rewritten by #5; the editor is simply a fixed 960x540 until then.

## Decisions already made

| Question                            | Decision                                                                                                                        |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Resizability                        | `can_resize` returns false. Resizability arrives with #5, together with the mailbox that makes it safe                          |
| Default editor size                 | 960x540 logical points. Cocoa uses logical pixels, so this is points and not backing pixels                                     |
| Who creates the `CAMetalLayer`      | The Metal backend, beneath the seam. `platform/view.zig` creates a bare `NSView` and never names a Metal or QuartzCore type     |
| What the seam declares              | Exactly `init`, `deinit`, and `frame`. Methods get added when there is a caller, per ADR 0005's "shaped to this algorithm"      |
| Where the gui vtable lives          | `plugin.zig`, as thin wrappers over an `Editor` in `gui.zig`, matching how `clap.state` and `clap.audio-ports` are already done |
| Whether a runtime `NSView` subclass | No. A plain layer-hosting `NSView` suffices without resize or per-frame callbacks. #5 registers a subclass when it needs one    |
| What drives the first frame         | `show`, and `set_parent` when the host has already shown the window. #5 replaces this with the display link                     |
| What tests may touch                | No test calls Metal or AppKit. The editor state machine is exercised without a view, so `zig build test` stays hermetic         |

## Changes

### `build.zig`: make the shader source embeddable

`@embedFile` resolves relative to the importing file and cannot escape the module root, which is `src/`. Add the shader to the core module's import table instead, in `coreModule` alongside the existing `addImport` calls:

```zig
mod.addAnonymousImport("scope.metal", .{ .root_source_file = b.path("shaders/scope.metal") });
```

`@embedFile("scope.metal")` then resolves through the import table and yields a null-terminated array, which is what `stringWithUTF8String:` wants. If that resolution does not work on the pinned toolchain, the fallback is a `b.addWriteFiles()` step generating a Zig file holding the source as a string constant. Do not move the shader under `src/`: `zig build validate-shaders` and `shaders/` as a directory are load-bearing in CI.

No new frameworks. `Cocoa`, `Metal`, `QuartzCore`, and `CoreVideo` are already linked at `build.zig:9`.

### `src/clap/c.zig`: layout assertions for the GUI ABI structs

Extend the existing `comptime` block in the pattern already there. A field-count change is how a CLAP bump announces itself, and a wrong offset is a crash inside someone else's DAW rather than a compile error.

- `clap_plugin_gui_t`, 15 fields, probing `is_api_supported`, `create`, `destroy`, `set_parent`, `show`, `hide`
- `clap_gui_resize_hints_t`, 5 fields
- `clap_host_gui_t`, 5 fields

`clap_window_t` is already asserted at `src/clap/c.zig:70`, and `cocoaView()` at `src/clap/c.zig:44` already exists as the single permitted path to the anonymous union. Nothing new is needed for either; the issue's constraint is satisfied by using the accessor that is already there.

Nothing needs restating. `CLAP_EXT_GUI` and `CLAP_WINDOW_API_COCOA` are `static const char[]` like `CLAP_PLUGIN_FACTORY_ID`, so they survive preprocessing and compare directly with the `std.mem.eql(u8, std.mem.span(x), &c.CLAP_…)` spelling already used at `src/main.zig:34`.

### `src/platform/objc.zig` (new): the Core Graphics types and two helpers

Small and dependency-free. It holds the geometry types that cross `objc_msgSend`, which `zig-objc` requires to be `extern` or `packed`:

```zig
pub const CGFloat = f64;
pub const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };
```

With a `comptime` assertion that `CGFloat` is 8 bytes and `CGRect` is 32, since both are true only on 64-bit and the whole calling convention depends on it.

Two helpers:

- `nsString(text: [*:0]const u8) objc.Object`, wrapping `+[NSString stringWithUTF8String:]`. Returns an autoreleased object, so callers must be inside a pool.
- `assertMainThread()`, which asserts `+[NSThread isMainThread]` in debug builds and compiles to nothing in release. This is the issue's "the view lifecycle belongs to the host main thread" constraint written as something checkable rather than as a comment. Call it at the top of every `Editor` method that touches AppKit.

ADR 0008 anticipated this file holding hand-rolled message-send wrappers. It does not need to: adopting `zig-objc` was the point of that ADR, and what is left is the types the wrappers pass.

### `src/gpu/iface.zig` (new): the seam

The load-bearing file of this change, per ADR 0005. It declares the vocabulary and forbids anything below it from surfacing:

```zig
pub const Size = struct { width: u32, height: u32 };

/// The native view the backend attaches its drawable surface to. Opaque on
/// purpose: on macOS this is an NSView, and what the backend hangs off it is
/// the backend's business.
pub const NativeView = *anyopaque;

pub const Error = error{ NoDevice, ShaderCompilationFailed, PipelineCreationFailed };

/// A fixed buffer the backend writes a human-readable failure into, so a Metal
/// compiler diagnostic reaches the host log without the gpu layer importing the
/// log or the clap layer importing Metal.
pub const Diagnostics = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diagnostics, text: []const u8) void  // truncates
    pub fn message(self: *const Diagnostics) []const u8
};

pub const Renderer = @import("metal/renderer.zig").Renderer;
```

Followed by a `comptime` block asserting the backend's signatures exactly:

```zig
comptime {
    assertSignature(@TypeOf(Renderer.init), fn (NativeView, Size, f64, *Diagnostics) Error!Renderer);
    assertSignature(@TypeOf(Renderer.deinit), fn (*Renderer) void);
    assertSignature(@TypeOf(Renderer.frame), fn (*Renderer) void);
}
```

That is the mechanized version of what ADR 0005 asks reviewers to do by eye. Every parameter and return type is drawn from this file's own vocabulary, so a backend that started taking an `objc.Object` or returning an `MTLDevice` fails to compile rather than passing review.

There is deliberately no `resize` and no texture creation. Both arrive with the phase that has a caller for them.

### `src/gpu/metal/renderer.zig` (new): the one backend

Holds four owned Objective-C objects and the layer. Everything transient runs inside an `objc.AutoreleasePool`; without one, `nextDrawable` leaks and the layer eventually stalls waiting for a free drawable.

`init(view, size, scale, diags)`, in order:

1. `MTLCreateSystemDefaultDevice()`, declared `extern "c" fn () ?*anyopaque`, returning `error.NoDevice` when null. It follows the Create Rule, so the caller owns it.
1. `newCommandQueue`.
1. `newLibraryWithSource:options:error:` over `@embedFile("scope.metal")` with nil options. On failure, copy `[[error localizedDescription] UTF8String]` into `diags` and return `error.ShaderCompilationFailed`. This is the payoff for carrying `Diagnostics`: a Metal compiler error is precise and useless if it never leaves the function.
1. `newFunctionWithName:` for `fullscreen_vertex` and `clear_fragment`, released once the pipeline is built.
1. An `MTLRenderPipelineDescriptor` with those functions and `colorAttachments[0].pixelFormat` set to `MTLPixelFormatBGRA8Unorm`, then `newRenderPipelineStateWithDescriptor:error:`, reporting `error.PipelineCreationFailed` the same way. The library is released here too; hot reload in phase 3 rebuilds it from source rather than keeping this one alive.
1. `+[CAMetalLayer layer]`, retained since it is autoreleased, with `device`, `pixelFormat` matching the pipeline, `framebufferOnly` true, `contentsScale` set to the passed scale, `drawableSize` set to the logical size times that scale, and `frame` set to the logical size.
1. Attach: `[view setLayer:layer]` then `[view setWantsLayer:YES]`, in that order, which is what makes the view layer-hosting rather than layer-backed. Reversing it lets AppKit install its own layer first.

`frame()` opens a pool and then: `nextDrawable`, returning immediately when it is nil, because under load that is normal and not an error; build an `MTLRenderPassDescriptor` over the drawable's texture with `loadAction = clear`, `storeAction = store`, and the dim clear colour; encode `setRenderPipelineState:` and `drawPrimitives:vertexStart:vertexCount:` for one triangle of three vertices; `endEncoding`; `presentDrawable:`; `commit`.

Both the load action's clear and the fullscreen triangle run, deliberately. The clear alone would produce the same picture without proving anything, and the whole point is that `shaders/scope.metal:30` executed on the GPU.

`deinit()` releases the pipeline, queue, device, and layer. It runs before the view is released, which `Editor.destroy` guarantees by ordering.

**The Metal enum values are hand-restated**, because Metal's headers are Objective-C and `translate-c` cannot read them: `MTLPixelFormatBGRA8Unorm` is 80, `MTLLoadActionClear` is 2, `MTLStoreActionStore` is 1, `MTLPrimitiveTypeTriangle` is 3. Put them in one named block with the same caveat `src/clap/c.zig:26` records for the feature strings: there is no header symbol to check them against, so the comment has to carry the risk. `MTLClearColor` is four `f64`s and needs the same `extern struct` treatment as `CGRect`.

Phase 3 moves the drawable to an sRGB pixel format when the tonemap needs palette maths in linear light. It does not matter for a flat colour, and changing it now would be a decision made in the wrong phase.

### `src/platform/view.zig` (new): the Cocoa view

A plain `NSView`, with no runtime class registration. The CLAP embedding protocol has the host call `set_size` on a drag, so a fixed-size editor needs no `setFrameSize:` override, and with no display link there is nothing that needs `viewDidChangeBackingProperties` yet. Issue #5 registers a subclass when it has a reason to.

```zig
pub const View = struct {
    object: objc.Object,

    pub fn create(width: u32, height: u32) ?View     // [[NSView alloc] initWithFrame:]
    pub fn attach(self: View, parent: *anyopaque) void  // [parent addSubview:]
    pub fn destroy(self: View) void                  // removeFromSuperview, then release
    pub fn setHidden(self: View, hidden: bool) void
    pub fn backingScale(self: View) f64
    pub fn handle(self: View) *anyopaque
};
```

`create` also sets an autoresizing mask of width plus height sizable. Nothing resizes the parent yet, but a host that sizes its window slightly differently from what `get_size` reported should still get a view filling it rather than a corner of one.

`backingScale` reads `[[self window] backingScaleFactor]`, falling back to `[[NSScreen mainScreen] backingScaleFactor]` and then to 1.0. The fallbacks are reachable: a view has no window until it is added to one, which is exactly why `Editor.setParent` attaches the view **before** reading the scale and only then builds the renderer.

### `src/clap/gui.zig` (new): the editor state machine

Everything about the editor that is not AppKit or Metal, so it can be tested without either:

```zig
pub const default_size: gpu.Size = .{ .width = 960, .height = 540 };

pub const Editor = struct {
    created: bool = false,
    view: ?platform.View = null,
    renderer: ?gpu.Renderer = null,

    pub fn isApiSupported(api: [*c]const u8, is_floating: bool) bool
    pub fn create(self: *Editor, api: [*c]const u8, is_floating: bool) bool
    pub fn destroy(self: *Editor) void
    pub fn setParent(self: *Editor, window: *const c.clap_window_t, diags: *gpu.Diagnostics) !void
    pub fn setHidden(self: *Editor, hidden: bool) bool
    pub fn size(self: *const Editor) gpu.Size
};
```

`isApiSupported` is the single place the api string is judged, shared by `is_api_supported` and `create`: not floating, not null, and equal to `CLAP_WINDOW_API_COCOA`. Floating windows are refused outright, which is legal because the header states embedding is supported by every host to date and is the case a plugin must support.

`setParent` reaches the parent through `clap.cocoaView(window)` and nothing else, refuses a null window or a null view pointer, then creates the view, attaches it, reads the backing scale, and builds the renderer. A failure at any step unwinds what it already built, so a host that reacts correctly to the false return is not left holding a half-constructed editor.

`destroy` tears down in the reverse order, renderer before view, and is safe to call when `create` failed, when `set_parent` never happened, and twice.

The first frame is drawn from `setHidden(false)`, and from `setParent` when the editor is already visible, since CLAP's documented order is `set_parent` then `show` but a host that reopens an editor may not repeat both.

### `src/clap/plugin.zig`: the vtable and the wiring

`Instance` gains one field, `editor: gui.Editor = .{}`. `destroy` calls `self.editor.destroy()` before freeing the instance: a host is supposed to call `gui.destroy` first, and one that does not should leak nothing.

The `clap.gui` vtable is fifteen thin `callconv(.c)` wrappers in a new section, matching how the state and audio-ports vtables are already written. Every one of them is filled in rather than left null, because a host is entitled to call any of them without checking:

| Callback                         | Behaviour                                                                                         |
| -------------------------------- | ------------------------------------------------------------------------------------------------- |
| `is_api_supported`               | True only for `cocoa` and not floating                                                            |
| `get_preferred_api`              | Assigns `&CLAP_WINDOW_API_COCOA` itself, not a copy, and false for floating                       |
| `create`                         | Delegates to `Editor.create`. Allocates nothing that needs a GPU, which is what keeps it testable |
| `destroy`                        | Delegates to `Editor.destroy`                                                                     |
| `set_scale`                      | Returns false. Cocoa is a logical-pixel API and the header says not to call this                  |
| `get_size`                       | Writes the fixed size, refusing null out-parameters                                               |
| `can_resize`                     | False, until #5                                                                                   |
| `get_resize_hints`               | False. There are no hints to give about a size that cannot change                                 |
| `adjust_size`                    | Writes back the fixed size and returns true, which is the honest closest usable size              |
| `set_size`                       | True only when asked for the size it already is                                                   |
| `set_parent`                     | Delegates to `Editor.setParent`, logging `@errorName(err)` and the `Diagnostics` text on failure  |
| `set_transient`, `suggest_title` | False and a no-op. Floating windows are refused, so neither should ever be called                 |
| `show`, `hide`                   | Delegate to `Editor.setHidden`                                                                    |

`set_parent` owns a `gpu.Diagnostics` on its stack and is the only place the Metal failure text reaches the host log, at `CLAP_LOG_ERROR`. That single log line is the difference between "the editor did not open" and "the fragment function is named wrong on line 30".

`getExtension` gains a `clap.gui` case. The comment at `src/clap/plugin.zig:367` promising it "arrives with issue #4" comes out.

### `src/main.zig` and `AGENTS.md`

`src/main.zig`'s test block names modules explicitly so their tests are collected. Add `gui.zig`, `gpu/iface.zig`, `gpu/metal/renderer.zig`, `platform/objc.zig`, and `platform/view.zig`.

`AGENTS.md`'s structure map gains the three new directories. `CLAUDE.md` is a symlink and needs no edit. Its gotchas section is where the `unnamed_0` warning already lives; add a line recording that the Metal enum values are hand-restated with nothing to check them against.

## Tests

The rule that shapes all of them: **no test creates an `NSView` or acquires a Metal device.** `zig build test` runs in CI on a runner whose GPU support is not something this project should depend on, and ADR 0009 exists to keep the build hermetic. The split between `gui.zig` and the two platform modules is what makes that possible.

| Area          | Cases                                                                                                                             |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| api gating    | `cocoa` embedded accepted; `cocoa` floating refused; `win32` refused; null refused                                                |
| editor        | `create` then `size` then `destroy`; `destroy` twice; `destroy` on an editor that was never created; `create` twice               |
| vtable        | Every function pointer in `gui_extension` is non-null; `get_extension` returns it for `clap.gui` and still null for `clap.params` |
| sizing        | `get_size` reports 960x540; `set_size` accepts that size and refuses any other; `adjust_size` writes the fixed size back          |
| null handling | `set_parent(null)`, `get_size(null, null)`, and `adjust_size(null, null)` return false rather than dereferencing                  |
| diagnostics   | `Diagnostics.set` truncates a message longer than the buffer instead of overflowing it                                            |
| geometry      | `comptime` assertions that `CGFloat` is 8 bytes and `CGRect` is 32                                                                |

Two existing tests assert the state this change ends. `src/clap/plugin.zig:756` expects `clap.gui` to return null, and `src/clap/plugin.zig:367`'s comment says the same. Both change rather than being extended.

## Verification

```bash
zig fmt --check build.zig src/
zig build test
zig build
zig build validate-shaders
clap-validator validate zig-out/Fosforo.clap
```

`validate-shaders` matters more than usual here: it is the only thing standing between a typo in `scope.metal` and a plugin whose editor fails to open with a runtime compiler error. `clap-validator` should hold at its current passing count; it does not exercise `clap.gui` deeply, so a green run means nothing regressed rather than that the editor works.

Then the parts only a host can answer:

```bash
zig build install-clap
```

In REAPER, launched from a terminal so `clap.log` mirroring is readable:

1. Insert Fósforo and open the editor. It must show a 960x540 view of flat dim grey, not black and not white.
1. Close and reopen it at least ten times. Every cycle must be clean, and the log must stay quiet.
1. Leave the editor open with audio playing, then close the project.

The leak check the issue asks for, against a REAPER that has been through those ten cycles:

```bash
heap "$(pgrep -x REAPER)" | grep -E "CAMetalLayer|MTLDevice|NSView"
```

Object counts must be flat across cycles rather than climbing by one per open. `leaks "$(pgrep -x REAPER)"` is the second opinion, and `MallocStackLogging=1` in the environment is what makes its output name the allocation site.

Then Logic, which is the reason clap-wrapper exists at all:

```bash
cmake -B build cmake/ && cmake --build build --target fosforo_all
auval -v aufx Fsfr Ctmn
```

If the editor opens in REAPER and not in Logic, `MTLCreateSystemDefaultDevice` returning null under the AU sandbox is the first thing to check. `cmake/narrow-au-resource-usage` narrows the component's resource claims, and GPU access is not among the things it drops, but it is the difference between the two hosts most likely to matter.

## Commits

Small commits at each logical boundary, all referencing `(#4)`:

1. `feat: assert the layout of the GUI ABI structs (#4)`
1. `feat: add the Objective-C types the platform and gpu layers pass (#4)`
1. `feat: define the renderer seam and compile the scope shader behind it (#4)`
1. `feat: host a Metal layer in a Cocoa view (#4)`
1. `feat: advertise clap.gui and embed the editor in the host window (#4)`
1. `docs: list the GUI, renderer, and platform modules in the structure map (#4)`

## What landed differently

Recorded because each was a decision made during execution rather than a slip.

**The seam and its backend share a commit.** The plan split them. They cannot be split: `iface.zig` aliases `metal/renderer.zig`, so the seam does not compile without a backend behind it. What did split cleanly was `platform/objc.zig`, which depends on nothing, so it became its own commit and the count stayed at six.

**Zig's lazy analysis nearly made this untested.** Function bodies are analysed only when something references them, so every message send in the renderer and the view was parsed and never type-checked: `zig build test` passed while `Renderer.init` was, in effect, uncompiled. A wrong selector signature would have surfaced at the first call from `gui.zig` rather than in the file that owns it. Both files now carry a `testing.refAllDecls(@This())` plus one for the struct, and the fix was confirmed the only way it can be, by planting a type error inside `init` and watching the build fail with `refAllDecls` in the reference trace.

**The `@embedFile` risk was retired before anything depended on it.** A throwaway project confirmed that an anonymous import resolves and yields `*const [N:0]u8`, so the terminator the `stringWithUTF8String:` path needs is there by construction. The `addWriteFiles` fallback was not needed.

**`auval` could not be run, for reasons that predate this change.** See the verification section.

## Results

`zig fmt --check`, `zig build test` (68 tests), `zig build`, and `zig build validate-shaders` all pass. `clap-validator` reports 21 passed and 0 failed, identical to the count before this change, which is the expected outcome: it does not exercise `clap.gui`, so it can only report the absence of a regression.

The runtime path was verified with a temporary in-process harness, since everything the issue asks for is runtime behaviour and none of the above touches it. Driving a real `NSApplication`, a real `NSWindow`, and the real vtable, it confirmed that the Metal device is acquired, `scope.metal` compiles at runtime from the embedded source, the pipeline builds, the layer attaches to the host's view, and a frame is drawn and presented.

**The leak criterion is met.** Under `leaks --atExit` with `MallocStackLogging`, no `NSView`, `CAMetalLayer`, `MTLDevice`, `MTLCommandQueue`, or pipeline object appears anywhere in the report, and the total is flat from 1 cycle to 400: 283 and 288 leaked allocations respectively, all of them `NSXPCConnection` cycles that AppKit's LaunchServices chatter creates and that vary run to run. A per-cycle leak would compound 400 times over and be unmissable.

The harness is deliberately not committed. It needs a GPU and a window server, so it could never join `zig build test` without reintroducing the non-hermetic build ADR 0009 exists to prevent. Promoting it to its own step, next to `validate-shaders` and on the same reasoning, is worth considering separately.

**`auval` remains unverified, and not because of this change.** The AUv2 component builds, and `cmake/narrow-au-resource-usage --check` passes against it, but `auval` cannot find it. The same failure reproduces from commit `92124e6`, before any of this work, and `auval -a` lists only the 23 Apple built-ins on this machine: no third-party Audio Unit registers, including ones installed and working in Logic. So this is an environment condition rather than a defect in the component, and the bundle's missing `_CodeSignature` is phase 6 work that the build plan already schedules. Opening the editor in Logic is still worth doing by hand.

## Out of scope

Recorded so these read as deliberate omissions:

- The `CVDisplayLink` render loop, triple-buffered per-frame resources, and the resize mailbox, which are issue #5. This change gives that issue a `frame()` to call and a seam to add `resize()` to.
- Resizability of any kind, including `viewDidChangeBackingProperties` and moving the editor between displays of different backing scales. All of it belongs with the mailbox.
- The `clap_host_gui` extension. Nothing here needs to ask the host to resize, show, or hide anything.
- Mouse input and the `NSView` subclass it needs, which is phase 5.
- Shader hot reload, which ADR 0009 records as the payoff for runtime compilation but which phase 3 collects.
- The persistent accumulation texture, decay, and everything else that makes the render look like hardware. Phase 3.

## Risks

| Risk                                                                             | Mitigation                                                                                                                                |
| -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `@embedFile` may not resolve through an anonymous import on the pinned toolchain | Fall back to a `b.addWriteFiles()` step generating a Zig file holding the source. Settle this first; everything else waits on it          |
| Metal enum values are restated with no header to check them against              | One named block, one comment carrying the risk, and a wrong value shows up immediately as a black or garbled drawable                     |
| Two copies of the plugin in one process                                          | Does not apply yet, because nothing registers an Objective-C class at runtime. It applies the moment #5 does, so it is recorded here      |
| `MTLCreateSystemDefaultDevice` returning null inside a sandboxed AU host         | The failure is reported through `clap.log` at error severity rather than crashing, and `auval` plus Logic are explicit verification steps |
| A host that calls `set_parent` without `create`, or `destroy` twice              | Every `Editor` method checks its own preconditions and the teardown is idempotent, which the tests cover directly                         |
| A stale backing scale if the editor's window moves to a different display        | Accepted for this issue. The drawable scales rather than breaking, and #5 fixes it properly with the backing-properties callback          |
