# Releases

Updated: 2026-09-25

[简体中文](README.zh-CN.md)

Use published release artifacts and their verification receipts for release status.
The [package contract](../RELEASE-PACKAGES.md) describes the consumable artifacts;
[promotion gates](PROMOTION-GATES.md) describe source and artifact boundaries.
Local progress and acceptance reports do not belong in this public index.

`npm run repo:version` checks that the public version
sources agree, the changelog names that version, and a tag names the same
version when tag validation is requested. The declarative source list is
`tools/release/source-version.json`. Run `npm run repo:version:test` when the
version contract or verifier changes.
