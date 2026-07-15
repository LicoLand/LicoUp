# Lico Arc Client Support Matrix

Product version: `0.0.1-alpha`

This report is generated from the release-target and capability catalogs. Optional external services never block a client release. `preview`, `deferred`, `unsupported`, and `unverified` are not support claims.

| Target | Build capability | Current release closure | Lico Arc client | Secure Mesh client-to-client | Mobile Relay | ChatGPT local OAuth | DeepSeek local API key | Gemini local OAuth | Kimi local OAuth | Conversation voice input |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| windows-x64 | available | not-in-current-closure | unverified | unverified | unverified | unverified | unverified | deferred | deferred | deferred |
| windows-arm64 | unavailable | not-in-current-closure | unverified | unverified | unverified | unverified | unverified | deferred | deferred | deferred |
| macos-x64 | available | not-in-current-closure | supported | preview | preview | unverified | unverified | deferred | deferred | deferred |
| macos-arm64 | available | selected-capable | supported | preview | preview | unverified | unverified | deferred | deferred | deferred |
| linux-glibc-x64 | available | not-in-current-closure | preview | preview | preview | unverified | unverified | deferred | deferred | deferred |
| linux-glibc-arm64 | available | selected-capable | preview | preview | preview | unverified | unverified | deferred | deferred | deferred |
| linux-musl-x64 | available | not-in-current-closure | preview | preview | preview | unverified | unverified | deferred | deferred | deferred |
| linux-musl-arm64 | available | not-in-current-closure | preview | preview | preview | unverified | unverified | deferred | deferred | deferred |
| android-arm64 | available | selected-capable | supported | preview | preview | preview | preview | deferred | deferred | deferred |
| ios-arm64 | unavailable | not-in-current-closure | unsupported | unverified | unverified | unverified | unverified | deferred | deferred | deferred |

## Release interpretation

- `Build capability` means a builder exists; it is not a release-readiness claim. Only targets marked `selected-capable` may enter the current local-install release closure.
- The first release closure authority is macOS arm64, Android arm64, and Linux glibc arm64. Other build-capable targets remain outside this closure and fail closed if selected.
- External-service rows disclose current integration support only. They are optional and never participate in client release readiness.
- Gemini and Kimi local OAuth are deferred on Android. Their incomplete descriptors remain fail-closed and are outside the current Android release scope.
- Conversation voice input is visible as deferred and is not a supported release capability.
