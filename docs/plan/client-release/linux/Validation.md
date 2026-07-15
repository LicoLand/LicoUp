# Linux Validation

1. Enumerate declared tuples and fail closed for unknown, duplicate, wrong-host, wrong-libc, wrong-architecture and unsupported selections.
2. Build each selected tuple from a clean pinned image; verify archive contents, manifest, executable architecture, libc boundary, profile and digest.
3. Exercise Secret Service success, denial, unavailable daemon, locked session, delete and restart; prove explicit memory-only behavior and absence of plaintext fallback.
4. Install and launch on clean target images with bounded event-driven smoke; run three isolated Linux topology nodes and verify independent state roots, no shared secret volume and deterministic teardown.
5. Only when a named Linux registry/channel is requested, sign or attest, publish and download the same digest; repeat install/launch, verify that channel's update/rollback continuity, and record its status separately from GitHub Release readiness.
6. Record parent architecture/shared Node ids, tuple, source revision, artifact and evidence digests in the child final receipt.

REQ-LIN-001 is proven by steps 1–2; REQ-LIN-002 by step 3; REQ-LIN-003 by step 4; REQ-LIN-004 is evaluated by step 5 only for a requested channel.
