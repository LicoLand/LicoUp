# Linux Release Architecture

```text
target tuple (arch + libc + package kind)
  → target-owned builder → one archive + manifest
  → architecture/libc/content verifier
  → publisher signature or attestation → protected publication
  → clean image install/launch/update receipt → child final reducer

measured Secret Service facts → native custody strategy
                              ├─ opaque protected store
                              └─ explicit memory-only
```

One artifact ledger distinguishes each tuple; direct and VM execution are evidence environments, not different artifact authorities. Smoke orchestration waits on typed readiness events with bounded deadlines and teardown instead of fixed sleeps. Each topology node owns a private state root and communicates only through the declared relay interface.

The child supplies platform custody and exact-artifact receipts to the parent; it does not decide the broader E2EE claim.

