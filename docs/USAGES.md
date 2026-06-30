# Lico-Arc Usage Guide

## Flutter Client

```bash
npm run client:get
npm run client:analyze
npm run client:test
npm run client:run:macos
```

## Native Sidecar

```bash
npm run client:native:test
npm run client:native:smoke
```

The `lico-client` binary is built from `crates/lico-client-native`.

## Packaging

```bash
npm run client:package:plan
npm run client:build:macos
npm run client:build:linux
npm run client:build:windows
npm run client:build:android
```

Platform builds require the matching platform toolchain. Windows bundles should
be built on Windows, Linux bundles on Linux, Android APKs with the Android SDK
and NDK, and macOS bundles on macOS.

## Verification

```bash
npm run client:verify
```

Use `LicoLite/LicoLite` for server-side Secure Client Mesh, relay, runtime
bootstrap, and self-hosted gateway verification.
