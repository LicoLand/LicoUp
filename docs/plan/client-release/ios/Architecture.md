# iOS Release Architecture

```text
pinned Xcode/Flutter toolchain → Apple-silicon simulator app
  → bundle/entitlement/native verification → simulator install/launch + FFI receipt
  → digest + minimum public verification metadata → GitHub Release decision
  ├→ separately blocked physical archive/custody/security claim
  └→ optional Apple distribution/TestFlight/store → channel-only decision

user action → LocalAuthentication context → Swift Keychain adapter
            ↔ typed Rust FFI capability/session contract → opaque secret operation
```

The Swift adapter is infrastructure behind the shared Rust custody trait. Capability facts, authorization outcome and session expiry cross FFI as typed values; secret bytes do not cross into generic Flutter payloads. One producer owns the artifact manifest and one child reducer binds distribution and physical receipts to it.

The local app-build branch closes on the simulator receipt. Physical Keychain/Secure Enclave,
real biometrics, and device encryption remain fail-closed security claims; projected callback support
is never promoted into those claims. Distribution remains separately unready only for the named channel.
