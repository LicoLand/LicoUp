# macOS Release Architecture

The child consumes the parent artifact schema, support reducer, opaque-secret port, capability graph and protocol core.

```text
canonical target tuple
  → deterministic Flutter/Rust build
  → distribution ZIP + immutable manifest
  → Developer ID signature → notarization/stapling
  → protected publication → public download
  → install/launch/update receipt → child final reducer

user action → LocalAuthentication context → opaque authorized-session handle
            → Keychain operations for the bounded workflow → explicit close/expiry
```

One macOS distribution producer owns the ZIP and manifest kind. Acceptance and receipt verifiers consume that exact schema; no fallback dispatch by unrelated artifact kind remains. One native authorization owner creates, validates and closes session handles. Platform store unavailability yields a typed unavailable or memory-only capability fact, never a hidden keyring substitution.

The local topology receipt and the production-release receipt are separate typed inputs. The first can feed Secure Mesh interoperability; only the second can feed selected-target publication readiness.

