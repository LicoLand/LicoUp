# Windows Validation

1. On a native Windows builder, build x64 from clean source and verify PE32+ x64 machine type, DLLs, native CLI, profile, source-state digest and executable digests. Confirm that the arm64 target fails closed until the pinned Flutter toolchain supplies a real native arm64 Windows build target; never accept relabeling.
2. Run DPAPI/Windows Hello success, denial, cancellation, background, expiry, delete and memory-only cases; hostile scans cover arguments, bridge values, logs and reports.
3. Exercise install/export/skill/journal operations with path traversal, reparse points, symlink races, locked files, interruption and simulated cross-volume boundaries; prove containment, rollback and crash consistency.
4. Install and launch each artifact on a clean matching host. Only when a named Windows production channel is requested, Authenticode-sign, publish, download, and repeat install/launch/update/rollback verification on the same digest; record that channel separately from GitHub Release readiness.
5. Run pairwise/trust/privacy acceptance and bind parent architecture/shared Node ids, target, source revision, artifact and evidence digests in the child final receipt.

REQ-WIN-001 is proven by step 1; REQ-WIN-002 by step 2; REQ-WIN-003 by steps 3–4; REQ-WIN-004 Secure Mesh acceptance by step 5 and optional channel status by the channel-only part of step 4.
