# Native release package templates

This directory contains source templates for native installer formats. It is
not a release output directory. The canonical target list, support state,
artifact names, and update authority live in
`tools/client-release-targets.json`; generated packages live under
`build/releases/<version>/<target-id>/`.

Templates are intentionally separated by ecosystem:

- `windows/msix/` owns direct MSIX identity and AppInstaller metadata.
- `linux/deb/` owns Debian-family DEB metadata for the APT channel.
- `linux/rpm/` owns RPM-family spec metadata for RPM repositories.
- `linux/pacman/` owns Arch Linux x64 Pacman metadata.
- `linux/pacman/` is also used by the separate Arch Linux ARM target; its
  architecture is selected by the catalog target, never inferred from a
  generic Linux label.
- `linux/alpine/` owns native Alpine APK metadata.
- `linux/appimage/` owns the separate direct-download AppImage surface.
- `ios/` owns the App Store IPA export options applied to the Xcode Archive.

The catalog is the only target authority. Each target supplies a distribution
family, compatibility baseline, package format, channel, architecture,
update authority, and owning build host. These templates describe package
inputs only; they do not grant signing credentials, repository acceptance,
store submission, or publication closure.

An internal portable bundle or verification archive must never be published
as a substitute for one of these native package targets.
