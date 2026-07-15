# Windows Release Architecture

```text
explicit win-x64 / win-arm64 target → target-owned clean builder
  → artifact manifest + PE/dependency verifier
  → digest + minimum public verification metadata → GitHub Release decision
  └→ optional Authenticode signature → protected platform publication/download
      → channel install/update/rollback receipt → channel-only decision

user action → Windows Hello/DPAPI authorization → opaque session/secret handle
filesystem mutation → no-follow containment → private durable journal → atomic commit
```

Architectures never share an ambiguous artifact alias. The shared Rust filesystem port owns containment and transaction semantics; Windows infrastructure implements native handles and durable replacement without a copy-over-symlink fallback. Skill and export operations consume that port instead of maintaining separate journals.

One child reducer joins architecture, custody, state, and Secure Mesh receipts for the exact digest and reports blocker codes without manufacturing platform evidence on another host. An optional channel reducer consumes publication evidence separately and cannot change the GitHub Release result.
