# macOS Release Architecture

The child consumes the parent artifact schema, support reducer, opaque-secret port, capability graph and protocol core.

```text
canonical target tuple
  → deterministic Flutter/Rust build
  → distribution ZIP + immutable manifest
  → digest + minimum public verification metadata → GitHub Release decision
  └→ optional Developer ID signature → notarization/stapling
      → platform publication/download/update receipt → channel-only decision

user action → LocalAuthentication context → opaque authorized-session handle
            → Keychain operations for the bounded workflow → explicit close/expiry
```

One macOS distribution producer owns the ZIP and manifest kind. Acceptance and receipt verifiers consume that exact schema; no fallback dispatch by unrelated artifact kind remains. One native authorization owner creates, validates and closes session handles. Platform store unavailability yields a typed unavailable or memory-only capability fact, never a hidden keyring substitution.

The local topology and exact-artifact receipts become inputs to GitHub Release and Secure Mesh decisions according to their own requirements. A production platform-channel receipt is a separate typed input and can affect only the named Developer ID/App Store channel.
