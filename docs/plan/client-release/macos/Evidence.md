# macOS Fresh Evidence

- Acceptance names a macOS distribution ZIP while receipt configuration still names an app bundle, and the dispatcher routes only the app-bundle kind correctly. The acceptance self-test fails before packaging.
- The local-identity installer self-test's positive fixture omits newly required manifest fields and fails.
- Production packaging and receipt semantics disagree on Developer ID, notarization, publication and update authority; transient CI artifact upload cannot close them.
- The selected macOS target is blocked by preview Secure Mesh pairwise support.
- The native secret store silently falls back to an ordinary keyring session when user-presence interaction is unavailable or disabled while reporting the store available. The advertised environment policy is not consumed by Rust.
- A fresh canonical release build fails at Flutter kernel compilation because current production shell call sites omit the newly required controller argument. No fresh runnable is produced, so the required launch step cannot execute.
- A release-target clean build, notarized public download, clean-machine launch, update continuity and real LocalAuthentication flow have not been observed in this audit.

Existing local build and release Cargo checks are useful baselines only. No historical receipt or old completed Node is accepted.
