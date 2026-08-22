# macOS direct-distribution compliance

[简体中文](MACOS-DIRECT-DISTRIBUTION.zh-CN.md)

This document covers only direct distribution outside the Mac App Store. The
repository does not claim that a release is complete until the final artifact
has passed real signing, notarization, stapling, and Gatekeeper verification.
The Mac App Store target remains blocked because its sandbox, process, update,
and submission model is a different product boundary.

## Apple requirements and repository controls

| Requirement | Repository control | Current status |
| --- | --- | --- |
| Use `Developer ID Application` for an app distributed outside the Mac App Store | The local platform-channel coordinator verifies the certificate type, team, application identifier, and profile authorization before packaging | Implemented; real release proof pending |
| Sign every executable, enable Hardened Runtime, include a secure timestamp, and omit `get-task-allow` | Nested code is inventoried and signed before the outer app; post-sign checks require Developer ID, runtime, timestamp, bounded entitlements, and exact nested-code closure | Implemented; real release proof pending |
| Submit Developer ID software to Apple notarization and staple the ticket | The app and final DMG are submitted with `notarytool`, stapled, revalidated, and assessed with `spctl`; a failure prevents the ready manifest | Implemented; real release proof pending |
| Request only resources the macOS app actually needs, and only when the current user action needs them | Camera purpose strings stay out of the macOS target. Automatic discovery probes only the Agent Scan Path Manifest, does not execute third-party Agent binaries at launch, resolves home from the environment (including firmlink-equivalent home paths), and classifies personal library roots, photo/music libraries, network volumes, iCloud containers, and other-app containers lexically without stating them. Token usage waits until Monitoring is opened. Opening an Agent's conversation interface may still read that Agent's own store | Implemented |
| Accurately disclose privacy behavior and bundled SDK practices | `PrivacyInfo.xcprivacy` and the bilingual privacy policy are inserted only into the macOS app/DMG release path. The manifest declares no tracking or project-operated collection and records the evidenced File Timestamp, System Boot Time, and User Defaults required-reason API uses | Implemented; must be re-audited when dependencies or data flows change |
| Protect users from changed or substituted update code | A macOS update must match the installed app's exact Developer ID designated requirement and team and pass code-signing, Hardened Runtime, timestamp, stapled-ticket, and Gatekeeper checks before replacement; the replacement script repeats the checks | Implemented; real update proof pending |
| Take responsibility for distributed code and dependencies | LicoUp no longer downloads, installs, updates, rolls back, or synchronizes skills. It only discovers local skills and can move a selected local directory to the system Trash. The release bundles the AGPL license, project notice, Flutter/Dart notices, and a target-filtered inventory plus available license texts from the locked Rust dependency graph | Implemented for skills and bundled notices |
| Keep protected credentials out of source and remote publication jobs | Signing and notarization inputs are local-only, secret-like files are rejected by repository gates and Rulesets, and the old GitHub/local-identity macOS archive and install entry points are disabled | Implemented |

## Direct distribution versus the Mac App Store

Apple's App Review Guideline 2.5.2 restricts App Store apps from downloading,
installing, or executing code that changes app functionality. That review rule
is not a substitute for the Developer ID rules used by this direct channel.
LicoUp nevertheless keeps skill delivery out of the product, and the repository
does not present the current process-running, self-update, or optional adapter
model as Mac App Store compatible.

Any optional third-party adapter or collaboration package obtained separately
from LicoUp remains third-party software. It is not made trustworthy by the
LicoUp app's notarization ticket. The publisher remains responsible for code
bundled in or distributed as part of an official LicoUp release, while users
remain responsible for software they independently place in local agent roots.

## Release acceptance boundary

A macOS release is not accepted merely because the scripts or certificates
exist. Acceptance requires one final, unmodified artifact to satisfy all of the
following in a single local release run:

1. Release metadata, privacy manifest, entitlements, certificate, profile, and
   toolchain preflight pass.
2. Every nested executable and the outer app are signed with Developer ID,
   Hardened Runtime, and a secure timestamp.
3. The app is notarized, stapled, and accepted by Gatekeeper.
4. The update ZIP is created only after the accepted app state.
5. The final DMG is signed, notarized, stapled, verified, and accepted by
   Gatekeeper.
6. Privacy, license, open-source notice, and third-party notices exist in the
   app resources and readable DMG root.
7. The digest-bound Apple session advances only after each preceding check;
   the public receipt is written only after public download, install, and
   stable-launch verification.

No repository CI workflow may publish a macOS direct artifact. The source
workflow creates the version's single `v<version>` Release directly from
`release`; Apple Release is the sole macOS publication authority and may drive
Apple and GitHub cloud operations only within one immutable per-release
authorization. It performs packaging on `macos-release-candidate`, appends the
five macOS assets to that same Release, and never replaces the source assets.
LicoUp does not implement an alternate macOS publisher or a background Apple
Release service.

## Authoritative Apple Release command

Install the private `apple-release` CLI from its standalone checkout first
(`npm install --global .` there). The checked-in configuration is declarative:
Apple Release owns the state machine, command contract, signing, notarization,
GitHub reconciliation, publication, resume behavior, and final receipt. LicoUp
owns only the product adapter in `tools/scripts/macos-release/`, which prepares
repository gates, the app build, and the signed update manifest in the form
Apple Release requires. The adapter's complete script and artifact inventory is
documented in that directory's `README.md`.

Signing keys, notarization credentials, and GitHub authentication remain in
their owning secure stores. Public output retains no certificate, account,
provider, credential, raw-output, or local-path value.

An Agent starts one exact release with:

```sh
npm run client:release:macos -- --version <version> --build <build>
```

Read-only preflight runs before the only authorization prompt. After acceptance,
Apple Release owns the exact accepted release source, platform branch, publication gates,
Developer ID package, app and DMG notarization/stapling/Gatekeeper checks, exact asset reconciliation,
publication, anonymous public download, install, and stable launch. It asks no
second question. The final receipt binds the immutable release source,
the five macOS artifacts appended to the existing source Release, Apple
results, and public installation proof.

## Primary Apple references

- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Configuring the Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
- [Adding a privacy manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
- [Protecting users from suspicious software](https://developer.apple.com/support/protecting-users-from-suspicious-software/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple developer agreements and guidelines](https://developer.apple.com/support/terms)
