# Bundled fonts

This directory holds the client's bundled typefaces. It is intentionally empty
in the repository: the font binaries are added by whoever performs the
typeface rollout, because a font asset must be vendored deliberately with its
license file rather than fetched during a build.

## Why the fonts are bundled and not fetched

`google_fonts` was previously declared as a dependency and never used. That
package downloads font files from `fonts.gstatic.com` at runtime, which would
create outbound network traffic from the client. LicoUp states that it does not
send data it does not need to send, so a runtime font fetch is not acceptable
regardless of how convenient it is. The dependency has been removed.

## Rollout

1. Download Geist Sans and Geist Mono (SIL Open Font License 1.1) from the
   official Vercel `geist-font` release.
2. Place these files in this directory:

   ```text
   assets/fonts/GeistSans-Regular.ttf     (weight 400)
   assets/fonts/GeistSans-Medium.ttf      (weight 500)
   assets/fonts/GeistSans-SemiBold.ttf    (weight 600)
   assets/fonts/GeistSans-Bold.ttf        (weight 700)
   assets/fonts/GeistMono-Regular.ttf     (weight 400)
   assets/fonts/GeistMono-Medium.ttf      (weight 500)
   assets/fonts/OFL.txt                   (license, must ship with the fonts)
   ```

3. Uncomment the `fonts:` block in `apps/desktop/pubspec.yaml`.
4. In `lib/src/frontend/shared/ui/lico_typography.dart`, set:

   ```dart
   static const String? sansFamily = 'Geist Sans';
   static const String? monoFamily = 'Geist Mono';
   ```

Steps 3 and 4 must land together. Naming a family that has no asset makes
Flutter fall back silently and differently on each platform, which is worse
than using the platform default deliberately.

## Chinese text

Geist is a Latin typeface with no CJK coverage, so Chinese resolves through the
fallback chain declared in `LicoTypography.sansFallback`
(PingFang SC → Microsoft YaHei → Noto Sans CJK SC → Noto Sans SC). The chain is
listed explicitly so mixed English/Chinese runs keep a consistent apparent
weight instead of letting each platform choose its own substitute.

Bundling a CJK face is deliberately out of scope: a full Chinese font adds
roughly 10-20 MB, and every target platform already ships a good one.
