# Bundled fonts

Geist Sans (400, 500, 600, 700) and Geist Mono (400, 500) are distributed with
the client under the [SIL Open Font License 1.1](OFL.txt). The unmodified files
come from [Vercel's official Geist repository](https://github.com/vercel/geist-font/tree/10dc7658f13c38a474cde201bb09a4617267545b/fonts).

The interface does not require them. The typographic baseline is the platform's
own family — `.AppleSystemUIFont`, `Segoe UI Variable Text`, `Roboto` or
`Ubuntu`, with the platform's Chinese face behind it — so a first launch and an
offline client render the whole interface from fonts the operating system
already has. Geist Mono keeps commands, paths, identifiers and numeric readouts;
the bundled sans face covers glyphs no platform supplies.

The interface family is a preference, not a constant. An installed font family
can be preferred through the appearance font preference, and
`LicoTypography.resolveFont` puts it first while keeping the platform chain
behind it, so a family that is not installed on this machine still renders in
the system face rather than in an empty style.

Chinese interface text is owned by the platform's own Chinese face: PingFang SC
and Hiragino Sans GB on macOS, Microsoft YaHei on Windows, Noto Sans CJK SC or
Source Han Sans SC on Linux. No CJK-sized font ships with the client, and the
running client never downloads one.
