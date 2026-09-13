# Bundled fonts

Geist Sans (400, 500, 600, 700) and Geist Mono (400, 500) are distributed with
the client under the [SIL Open Font License 1.1](OFL.txt). The unmodified files
come from [Vercel's official Geist repository](https://github.com/vercel/geist-font/tree/10dc7658f13c38a474cde201bb09a4617267545b/fonts).

The build bundles these assets; the running client never downloads fonts.
Geist Sans owns interface and reading text. Geist Mono owns commands, paths,
identifiers and numeric readouts. Chinese interface text uses bundled Noto Sans
SC, distributed under its
[SIL Open Font License 1.1](NotoSansSC-OFL.txt). The unmodified variable font
comes from the [official Google Fonts source](https://github.com/google/fonts/tree/809e4d8b8d7e9364a914909bb777679606c178b8/ofl/notosanssc).
The platform fallback chain covers only glyphs absent from the bundled fonts.
Latin and Chinese interface text are available completely offline.

Noto Sans SC is registered once. The supported Flutter engine applies
`FontWeight` directly to its variable weight axis, avoiding repeated font-file
registrations for each weight. See [Flutter's variable-weight behavior](https://docs.flutter.dev/release/breaking-changes/font-weight-variation).
