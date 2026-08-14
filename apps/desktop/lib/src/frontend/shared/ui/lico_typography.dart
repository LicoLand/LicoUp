import 'package:flutter/material.dart';

/// The client's typographic system.
///
/// Two rules govern every text style in the client:
///
/// 1. **Size and weight come from a role, never from a literal.** Feature code
///    reads `Theme.of(context).textTheme.*` or a helper here. A local
///    `TextStyle(fontSize: 13.5)` is a defect — it is invisible to the scale
///    and cannot respond to a density change.
/// 2. **Numbers that change in place use [numeric].** Proportional digits
///    reflow as values update, which makes charts, token counters, byte sizes,
///    and timestamps visibly jitter.
abstract final class LicoTypography {
  /// The bundled UI family, or `null` to use the platform default.
  ///
  /// Set this to `'Geist Sans'` at the same time as declaring the font in
  /// `pubspec.yaml`. Declaring a family that has no asset makes Flutter fall
  /// back silently and inconsistently across platforms, so the two changes
  /// must land together.
  static const String? sansFamily = null;

  /// The bundled monospace family, or `null` to use the platform chain.
  ///
  /// Set this to `'Geist Mono'` together with its `pubspec.yaml` declaration.
  static const String? monoFamily = null;

  /// Fallback chain for the UI family.
  ///
  /// A Latin-only bundled face has no CJK coverage, so Chinese text resolves
  /// through this chain. Listing the platform CJK faces explicitly keeps the
  /// apparent weight of mixed English/Chinese runs consistent instead of
  /// letting each platform pick an arbitrary substitute.
  static const List<String> sansFallback = <String>[
    'PingFang SC',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Noto Sans SC',
  ];

  /// Fallback chain for monospace. Ends at the generic family so a platform
  /// without any of the named faces still renders fixed-pitch text.
  static const List<String> monoFallback = <String>[
    'SF Mono',
    'Menlo',
    'Cascadia Mono',
    'Consolas',
    'DejaVu Sans Mono',
    'monospace',
  ];

  /// Tabular figures. Applied to every role that renders changing numbers.
  static const List<FontFeature> tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// The monospace style for paths, commands, ids, and code.
  ///
  /// Monospace is a semantic choice, not decoration: it marks text that is
  /// exact and machine-meaningful, so the reader knows it can be copied
  /// verbatim.
  static TextStyle mono({
    required Color color,
    double fontSize = 13,
    FontWeight fontWeight = FontWeight.w400,
    double height = 1.35,
  }) {
    return TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
      fontFeatures: tabular,
    );
  }

  /// The style for a small group label above a list or menu section.
  ///
  /// Eyebrows carry structure without consuming a heading level, which keeps
  /// dense panels navigable without a second type size. The values are the
  /// ones the sidebar, palette, and menu group labels converged on; they used
  /// to be restated inline at every call site with drifting weight and
  /// tracking.
  static TextStyle eyebrow({required Color color}) {
    return TextStyle(
      fontFamily: sansFamily,
      fontFamilyFallback: sansFallback,
      color: color,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      height: 1.2,
      letterSpacing: 0.4,
    );
  }

  /// The compact label for a text action in a sidebar or toolbar.
  ///
  /// Action labels identify commands and navigation controls, not content
  /// headings. Keeping this role separate prevents a new text action from
  /// inheriting title emphasis merely because it occupies a prominent row.
  static TextStyle actionLabel({required Color color}) {
    return TextStyle(
      fontFamily: sansFamily,
      fontFamilyFallback: sansFallback,
      color: color,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.3,
      letterSpacing: 0.1,
    );
  }

  /// The style for a large metric value in a monitoring tile.
  static TextStyle metric({required Color color, double fontSize = 24}) {
    return TextStyle(
      fontFamily: sansFamily,
      fontFamilyFallback: sansFallback,
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.1,
      letterSpacing: -0.4,
      fontFeatures: tabular,
    );
  }

  /// Builds the application text theme.
  ///
  /// The scale steps by roughly 1.2 between adjacent levels
  /// (10 → 11 → 12 → 13 → 14 → 15 → 18 → 20 → 24 → 28). Negative tracking on
  /// the large sizes counteracts the optical looseness of big text; positive
  /// tracking on the small sizes keeps them legible.
  static TextTheme textTheme({
    required Color text,
    required Color textSecondary,
    required Color textMuted,
  }) {
    TextStyle style(
      double size,
      FontWeight weight,
      Color color, {
      double? height,
      double? letterSpacing,
      bool numeric = false,
    }) {
      return TextStyle(
        fontFamily: sansFamily,
        fontFamilyFallback: sansFallback,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontFeatures: numeric ? tabular : null,
      );
    }

    return TextTheme(
      // Display: brand moments only — empty states, onboarding, the logo
      // lockup. Never used inside dense content.
      displaySmall: style(
        32,
        FontWeight.w700,
        text,
        height: 1.15,
        letterSpacing: -0.6,
      ),
      headlineLarge: style(
        28,
        FontWeight.w700,
        text,
        height: 1.2,
        letterSpacing: -0.4,
      ),
      headlineMedium: style(
        24,
        FontWeight.w700,
        text,
        height: 1.25,
        letterSpacing: -0.3,
      ),
      headlineSmall: style(
        20,
        FontWeight.w700,
        text,
        height: 1.3,
        letterSpacing: -0.2,
      ),
      titleLarge: style(
        18,
        FontWeight.w600,
        text,
        height: 1.3,
        letterSpacing: -0.15,
      ),
      titleMedium: style(15, FontWeight.w600, text, height: 1.35),
      titleSmall: style(13, FontWeight.w600, text, height: 1.4),
      // Body large is the conversation reading size. Its line height is the
      // loosest in the scale because message text is read in long runs.
      bodyLarge: style(14, FontWeight.w400, text, height: 1.5),
      bodyMedium: style(13, FontWeight.w400, textSecondary, height: 1.45),
      bodySmall: style(12, FontWeight.w400, textMuted, height: 1.4),
      labelLarge: style(
        13,
        FontWeight.w600,
        text,
        height: 1.3,
        letterSpacing: 0.1,
      ),
      labelMedium: style(
        12,
        FontWeight.w500,
        textSecondary,
        height: 1.3,
        numeric: true,
      ),
      labelSmall: style(
        11,
        FontWeight.w500,
        textMuted,
        height: 1.3,
        letterSpacing: 0.2,
        numeric: true,
      ),
    );
  }
}
