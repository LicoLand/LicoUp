# Lico Arc Client Support Matrix

English · [简体中文](client-support-matrix.zh-CN.md) · [Home](../../README.md)

Product version: `0.0.1-alpha`

This file is generated from the client catalogs. A build target is not a support claim.

| Target | Build | GitHub Release eligible | Physical/device evidence | Store publication | Client | Peer encryption | Mobile relay |
| --- | --- | --- | --- | --- | --- | --- | --- |
| windows-x64 | available | not eligible | not claimed | not claimed | preview | preview | preview |
| windows-arm64 | unavailable | not eligible | not claimed | not claimed | unverified | unverified | unverified |
| macos-x64 | available | not eligible | not claimed | not claimed | supported | preview | preview |
| macos-arm64 | available | eligible | not claimed | not claimed | supported | preview | preview |
| linux-glibc-x64 | available | not eligible | not claimed | not claimed | preview | preview | preview |
| linux-glibc-arm64 | available | eligible | not claimed | not claimed | preview | preview | preview |
| linux-musl-x64 | available | not eligible | not claimed | not claimed | preview | preview | preview |
| linux-musl-arm64 | available | not eligible | not claimed | not claimed | preview | preview | preview |
| android-arm64 | available | eligible | not claimed | not claimed | supported | preview | preview |
| ios-simulator-arm64 | available | not eligible | simulator only | not claimed | supported | preview | preview |
| ios-arm64 | unavailable | not eligible | not claimed | not claimed | unverified | unverified | unverified |

## Meaning

- `supported` means the current target-specific client checks accept the feature; it does not imply distribution readiness.
- `preview` means the feature is still changing.
- `unverified` means there is no current support claim.
- `unsupported` means the feature must not be presented as available.
- `eligible` means a release operator may explicitly select that target; it does not mean any current release includes it.
- Feature status does not establish native-host, physical-device, biometric, hardware-custody, or cross-device evidence. Those claims remain `not claimed`; a simulator row proves only its simulator closure.
- Store publication is not claimed by this matrix and requires a separate channel-specific result.
- Peer content is encrypted by the sending client. Sensitive runtime data stays local.
