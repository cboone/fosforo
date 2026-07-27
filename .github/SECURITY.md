# Security Policy

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab (in the top navigation bar, next to Issues/Pull Requests)
1. Click "Report a vulnerability" in the left sidebar under Advisories
1. Fill out the form with details

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment:** Within 24 hours
- **Initial assessment:** Within 48 hours
- **Resolution target:** Depends on severity, but as soon as possible

### What Qualifies as a Security Issue

An audio plugin runs in-process inside a host that holds the user's entitlements, so the threat model is mostly about what a malicious project file or plugin state can do.

- Memory-safety faults reachable from host-supplied input: audio buffers, parameter values, or saved plugin state
- Crashes or corruption triggered by malformed or hostile saved state
- Path traversal when loading or saving state and presets
- Sensitive data exposure, including anything written outside the plugin's expected locations
- Credential exposure risks

### Out of Scope

- Issues in upstream dependencies (report to them directly). This includes CLAP, clap-wrapper, and zig-objc
- Issues requiring physical access to the machine
- Social engineering attacks
- Crashes only reproducible with a host that violates the CLAP threading contract
