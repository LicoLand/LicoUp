# Release packages

English (normative) · [简体中文](RELEASE-PACKAGES.zh-CN.md) ·
[Compatibility](COMPATIBILITY.md) · [Runbook](RUNBOOK.md)

LicoUp has no universal release archive. A release request selects one or more
exact package targets. Every selected target produces its own native installer,
channel metadata, checksum, and package manifest.

The structured authority is
[`tools/client-release-targets.json`](../tools/client-release-targets.json).
`npm run client:support-matrix:sync` projects its current support state into the
[compatibility matrix](COMPATIBILITY.md). Do not duplicate target eligibility in
hand-maintained documentation.

Every catalog entry is an exact tuple with these required fields: `platform`,
`distributionFamily`, `baseline`, `packageFormat`, `channel`, `arch`,
`updateAuthority`, and `buildHost`. `platform` identifies the operating-system
surface; `distributionFamily` identifies the native distribution or store
family; `baseline` is the minimum compatibility contract; and `buildHost` is
the owning host identity for the recipe. A runtime target is an implementation
detail and never substitutes for a package target.
The v4 catalog rejects undeclared fields in the catalog, target, artifact,
update, and builder objects instead of silently treating older shapes as valid.

## Canonical output layout

```text
build/releases/<product-version>/
├── macos-direct-arm64/
│   ├── LicoUp-macos-arm64.dmg
│   ├── LicoUp-macos-arm64.dmg.sha256
│   ├── LicoUp-macos-arm64-update.zip
│   ├── LicoUp-macos-arm64-update.zip.sha256
│   ├── LicoUp-macos-arm64.build.json
│   └── LicoUp-macos-direct-arm64.package.json
└── android-direct-arm64-v8a/
    ├── LicoUp-android-arm64.apk
    ├── LicoUp-android-arm64.apk.sha256
    ├── LicoUp-android-arm64.build.json
    └── LicoUp-android-direct-arm64-v8a.package.json
```

There is no archive around this tree. Each leaf directory is independently
stageable and verifiable. The package manifest binds the target, runtime target,
platform, distribution family, compatibility baseline, distribution channel,
native format, architecture, product version, build number, source-state and
target-catalog digests, update authority, owning build host, file sizes, and
SHA-256 digests. The generic v4 platform-builder manifest independently repeats
the distribution family, baseline, update authority, and build host while
binding every produced package artifact to the same target catalog, runtime
target, source state, version, and build number. Existing direct-platform
manifests are accepted only through their stricter platform-specific binding.

## Target model

A package target is the tuple `platform × distribution family × compatibility
baseline × channel × native format × architecture`, plus its update authority
and owning build host. A runtime target such as `linux-glibc-arm64` is only the
program execution ABI; it is not a publishable package.

| Target family | Baseline | Native format | Channel | Build host | Update authority |
| --- | --- | --- | --- | --- | --- |
| macOS direct (arm64) | macOS 11.0 | DMG | local-only Developer ID channel | macOS arm64 | signed HTTP manifest |
| macOS App Store (arm64) | macOS 11.0 | PKG | App Store | macOS arm64 | App Store |
| Windows direct (x64) | Windows 10.0.19041 | MSIX | direct | Windows x64 | AppInstaller |
| Windows Store (x64) | Windows 10.0.19041 | MSIX upload | Microsoft Store | Windows x64 | Microsoft Store |
| Debian (arm64, x64) | Debian 12 | DEB | APT repository | matching Linux host | APT repository |
| RPM (arm64, x64) | Fedora 39 RPM | RPM | RPM repository | matching Linux host | RPM repository |
| Arch Linux (x64) | Arch Linux rolling | `.pkg.tar.zst` | Pacman repository | Linux x64 | Pacman repository |
| Arch Linux ARM (arm64) | Arch Linux ARM rolling | `.pkg.tar.zst` | Pacman repository | Linux arm64 | Pacman repository |
| Alpine (arm64, x64) | Alpine 3.20 | APK | Alpine repository | matching Linux host | Alpine repository |
| AppImage (arm64, x64) | glibc 2.31 | AppImage | direct | matching Linux host | AppImage update information |
| Android direct (arm64-v8a) | Android API 21 | APK | direct | macOS arm64 release host | manual download |
| Android Play (arm64-v8a) | Android API 21 | AAB | Google Play | macOS arm64 release host | Google Play |
| iOS App Store (arm64) | iOS 13.0 | IPA | App Store | macOS arm64 | App Store |

The catalog contains one row per architecture where the native package differs;
the parenthesized architectures above are separate target IDs. Debian, RPM,
Arch Linux, Arch Linux ARM, Alpine, and AppImage are intentionally separate
families. There is no generic Linux package target.

`packageBuildSupported` and `releaseSupported` are independent facts. A recipe
can be buildable while release closure is still blocked. The macOS direct
target is intentionally blocked from the generic/remote release builder and
must use the explicitly authorized local Developer ID coordinator. A blocked recipe carries `packageBlockers`; a package whose
external publication or receipt is incomplete carries `releaseBlockers`.
These are stable typed codes such as `apt_repository_publication_not_implemented`
or `linux_native_package_receipt_pending`; they do not claim credentials,
repository acceptance, signing, notarization, or store submission.

A `tar.gz` bundle may still carry a build into an isolated verification host.
It is an internal evidence carrier and must not appear in the release target
catalog or a public release asset set.

## Commands

Plan one exact package without building it:

```sh
npm run client:release:plan -- --target macos-direct-arm64
```

Plan several independent packages in one request:

```sh
npm run client:release:plan -- \
  --targets macos-direct-arm64,android-direct-arm64-v8a
```

Repeated `--target` and comma-separated `--targets` may be combined. Duplicates,
unknown targets, empty tokens, and ambiguous environment/CLI selection are
rejected. `--all` is available for catalog planning; building still fails closed
unless every selected target has an implemented builder for the current host.

Build, stage, or verify supported targets with the same selector:

```sh
npm run client:release:build -- --target android-direct-arm64-v8a
npm run client:release:stage -- \
  --target macos-direct-arm64 \
  --target android-direct-arm64-v8a
npm run client:release:verify -- \
  --targets macos-direct-arm64,android-direct-arm64-v8a
```

`stage` consumes already-built native artifacts and writes only the canonical
leaf directories. `verify` rejects extra files, symbolic links, stale package
metadata, digest mismatches, and checksum mismatches.

`build` runs the target's complete native recipe before atomically staging the
selected set. Generic and remote macOS direct builds fail closed. An explicitly
authorized local operator uses `client:verify:macos-distribution:preflight`
followed by `client:build:macos:platform-channel`; the coordinator requires
Developer ID, Hardened Runtime, secure timestamps, notarization, stapling, and
Gatekeeper verification. Android direct requires its protected APK signing
inputs. Missing platform authority fails before a
canonical package leaf is replaced.

## Publication

The GitHub workflow accepts the same comma-separated exact target selection,
but rejects the macOS direct target. macOS signing, notarization, packaging,
and publication remain local-only and require separate explicit authorization.
Its prepare phase may matrix every target whose `packageBuildSupported` value is
true and selects the target's declared runner labels. The workflow bootstraps
the shared Node, Rust, and Flutter toolchains; each owning runner must provide
the native packaging tools and authorized build credentials declared by that
target's typed preflight. Prepare only builds, stages, verifies, and uploads
packages; it never submits to a store or package repository. Its publish phase
accepts only `releaseSupported` targets, downloads every package from one
source-bound prepare run, verifies the exact target-directory set and every
installer digest, requires the exact public source-first `v<version>` Release,
creates one cross-target consumer verification manifest that also binds every
package-manifest digest, and appends only the selected platform assets after the
complete selected set succeeds. Existing public assets are never replaced.

Store and package-repository submission remain separate channel operations.
Building an AAB, MSIX upload bundle, DEB, RPM, Pacman package, Alpine package, or
App Store IPA never proves that the corresponding store or repository has
accepted it.

## Template ownership

Source templates live under [`apps/desktop/packaging/`](../apps/desktop/packaging/).
They follow the native metadata shapes documented by
[MSIX/AppInstaller](https://learn.microsoft.com/windows/msix/app-installer/app-installer-file-overview),
[Debian Policy](https://www.debian.org/doc/debian-policy/),
[Fedora RPM packaging](https://docs.fedoraproject.org/en-US/packaging-guidelines/),
[Arch package guidelines](https://wiki.archlinux.org/title/Creating_packages),
[Alpine packaging](https://wiki.alpinelinux.org/wiki/Creating_an_Alpine_package),
and [AppImage packaging](https://docs.appimage.org/packaging-guide/index.html).
Android store submission follows the
[Android App Bundle](https://developer.android.com/guide/app-bundle) model;
Apple store submissions remain Xcode/App Store Connect archives.

The direct macOS compliance boundary is documented in
[macOS direct-distribution compliance](platforms/MACOS-DIRECT-DISTRIBUTION.md).
