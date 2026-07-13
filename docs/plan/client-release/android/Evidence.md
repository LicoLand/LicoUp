# Android Fresh Evidence

- The release workflow does not set the Android target selection, so a macOS host can infer the wrong acceptance target. It also does not build a same-source desktop CLI required by the current physical topology contract.
- Artifact kind, path and signature-policy fields agree between current Android acceptance and receipt configuration; this is a useful schema baseline only.
- The production bridge writes sensitive account/relay/pairing diagnostic metadata on every initialization without consent, protection, rotation or bound.
- The Keystore policy contains an authentication-mode `NONE` persistent candidate. Existing tests prove that path, but do not prove the client's unified authorization requirement or prevent downgrade when authentication is available.
- Secure Mesh pairwise support for the selected Android target remains preview.
- No authorized physical install/launch, production signing, public-channel download, update continuity or real BiometricPrompt/Keystore flow was executed in this audit.

