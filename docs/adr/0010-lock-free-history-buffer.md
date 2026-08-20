# 0010. Lock-free circular history buffer, not a queue

**Status:** Accepted

## Context

The architecture reduces to three threads that must never block each other:

- The host's **audio thread** produces samples. The process callback taps the signal here.
- A **display-link thread** (`CVDisplayLink`) consumes the most recent samples to draw, at vsync.
- The host's **main thread** owns the AppKit view lifecycle: creation, resize, parent handoff.

Keeping these boundaries clean is what prevents audio dropouts. The audio callback runs on an OS-scheduled thread with hard deadlines: it may not allocate, may not take a lock a lower-priority thread can hold, may not make a syscall, and may not be interrupted by a runtime.

The instinctive structure for passing data between a producer and a consumer is a queue. For this problem that is the wrong choice.

## Decision

Connect the audio and render threads with a **circular history buffer** carrying a single monotonically increasing write cursor. Not a queue.

## Consequences

A scope wants the most recent *window* and is perfectly happy to overwrite everything older. A queue models "deliver every item exactly once," which is neither needed nor wanted, and costs complexity to provide.

The protocol is small enough to state completely: the producer writes samples and publishes the advanced cursor with release semantics; the consumer reads a trailing window relative to an acquire load of that cursor.

Because capacity is on the order of a second while any display window is tens of milliseconds, the producer cannot realistically lap the consumer between publish and copy. A seqlock-style retry loop is therefore unnecessary. This one structure is the entire concurrency story between the two threads: no lock, no allocation, no room for priority inversion.

**Real-time safety is enforced structurally, not by discipline.** The DSP path takes an allocator parameter and is handed a fixed-buffer allocator sized at `activate` time, so "does the audio path touch the heap" becomes a fact about the call graph. Debug builds assert no allocation occurs in `process`.

For an analyzer whose process callback passes audio through and taps one channel, there is genuinely almost nothing real-time-unsafe to get wrong, which is part of why this is a good first project in this stack.

**Two rules follow for the other boundary.** The render thread touches Metal only and must never mutate AppKit state; any such mutation is marshalled to the main thread. And resize is the one genuine seam that cannot be fully lock-free: the resize callback arrives on the main thread and must reallocate textures the render thread is using. That is handled by a pending-resize flag serviced at the top of the render tick, before the old textures are touched. It is a handful of lines, and getting it wrong produces a use-after-free that appears only when a user drags the window during playback.

## Amended by issue #44: how the ordering is checked

This ADR specifies the release/acquire pairing and says nothing about how anyone would know it still held. Nothing did. Every test of `src/dsp/ring.zig` was single-threaded, so replacing the release store with a `.monotonic` one passed all of them, and a reading of the module was the only check that existed. The obligation to close that was handed forward between three plans without being closed, on a premise that did not hold.

[ADR 0016](0016-verify-the-ring-ordering-with-tsan.md) adds the missing clause: the pairing is verified by running `write` and `read` on two threads under Thread Sanitizer, on Linux, in CI, and a source canary catches the weakening locally. It also states plainly what that does not cover, which is the torn-window path this ADR's margin argument makes acceptable in the first place.

Nothing above is superseded. The protocol, the margin, and the reasons for a history buffer rather than a queue all stand.
