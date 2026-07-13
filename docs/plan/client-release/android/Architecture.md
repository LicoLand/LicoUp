# Android Release Architecture

The child consumes the parent target schema, capability graph, opaque-secret interface, protocol core and receipt schema.

```text
explicit android-arm64 selection → pinned SDK/NDK/JDK/Flutter build
  → APK/store artifact + manifest → ABI/native-library/signature verification
  → fresh emulator install/launch + simulated auth/FFI receipt
  → separately blocked physical custody → publication/download/update receipt

user action → BiometricPrompt/device credential → CryptoObject/session handle
            → Keystore operation → bounded close/expiry
```

Policy selection is a typed strategy decision over measured lockscreen, authenticator and key capabilities. It reports exact facts and never ranks incomparable strategies with a fabricated numeric level. A no-authentication persistent key cannot satisfy REQ-AND-001; an explicit memory-only strategy remains available.

Diagnostics are a consented bounded service, not an unconditional lifecycle side effect. Device evidence records only allowlisted target, build, install, launch and capability outcomes; device identity and runtime data are excluded.

The emulator receipt closes only local app construction and integration. It is not a substitute
for hardware-backed Keystore, real biometrics or physical cross-device encryption.
