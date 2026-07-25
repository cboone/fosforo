# 0001. Mac-first, Apple Silicon primary

**Status:** Accepted

## Context

This is a single-developer project. Every axis of platform variation multiplies the decision lattice, and the multiplication compounds: three audio-thread contracts, three SIMD targets, two memory architectures, several windowing systems, several signing regimes.

The boutique end of the plugin market is substantially populated by Mac-first shops that build against Apple's frameworks directly, because that is the platform their author works on. It is a well-precedented place to stand.

## Decision

Target macOS on Apple Silicon as the primary and only platform. Treat Intel Mac support as a retained option, not a commitment.

## Consequences

Committing to one platform and one vendor removes whole categories of failure rather than merely reducing code:

- **One audio-thread contract.** Core Audio's rules, rather than the intersection of Core Audio's, MMCSS's, and Linux's differing and differently strict rules. This also frees the project to use macOS mechanisms directly (`os_workgroup`, `os_unfair_lock`, `dispatch_semaphore`) instead of abstracting over three implementations.
- **One SIMD target.** 128-bit NEON, uniformly present. No runtime feature detection, no dual code paths, no scalar fallback.
- **Unified memory.** Verified on this hardware: the Metal device reports `hasUnifiedMemory: true`. Getting sample data to the renderer is a cache concern rather than a discrete-GPU transfer, and shared storage-mode buffers can be designed for rather than merely tolerated. A cross-platform design could never assume this.
- **One of everything else.** One graphics API, one shading language, one windowing system for the GUI handoff, one state convention, one signing and notarization story, one installer format, one binary architecture.
- **Access to Metal's stronger capabilities.** A portable abstraction must program to the weakest target's guarantees. Metal-direct unlocks tile memory, specific threadgroup behaviors, argument buffers, and tight compute-render integration. Latent for the basic renderer, relevant if the compute-splatting variant is pursued.

The cost is that Windows and Linux users are not served. See [ADR 0005](./0005-metal-behind-a-renderer-seam.md) for how much room is left for that to change.
