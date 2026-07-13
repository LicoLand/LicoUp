# Windows Validation

1. On native Windows builders, independently build x64 and arm64 from clean source; verify PE machine type, DLLs, native CLI, profile and digest.
2. Run DPAPI/Windows Hello success, denial, cancellation, background, expiry, delete and memory-only cases; hostile scans cover arguments, bridge values, logs and reports.
3. Exercise install/export/skill/journal operations with path traversal, reparse points, symlink races, locked files, interruption and simulated cross-volume boundaries; prove containment, rollback and crash consistency.
4. Install and launch each artifact on a clean matching host; then Authenticode-sign, publish, download and repeat install/launch/update/rollback verification on the same digest.
5. Run pairwise/trust/privacy acceptance and bind parent architecture/shared Node ids, target, source revision, artifact and evidence digests in the child final receipt.

REQ-WIN-001 is proven by step 1; REQ-WIN-002 by step 2; REQ-WIN-003 by steps 3–4; REQ-WIN-004 by steps 4–5.

