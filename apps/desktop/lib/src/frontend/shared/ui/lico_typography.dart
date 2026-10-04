import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The font preferences that name no family.
///
/// They ask for the platform's own interface face, which is what a first launch
/// and an offline client render with: the operating system already has these
/// glyphs, so no bundled font has to be present.
abstract final class LicoFontPreference {
  /// The default preference: the platform's own interface face.
  static const String system = 'system';

  /// The persisted spelling of the same preference.
  static const String systemDefault = 'system-default';

  static const List<String> values = <String>[system, systemDefault];

  /// Whether [value] names a font family to prefer over the platform's.
  static bool namesFamily(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isNotEmpty && !values.contains(normalized);
  }
}

/// The family chain one font preference resolves to.
final class LicoFontSelection {
  const LicoFontSelection({required this.family, required this.fallback});

  /// The family the interface asks for first.
  final String family;

  /// The families consulted after it, most platform-specific first.
  final List<String> fallback;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LicoFontSelection &&
          other.family == family &&
          other.fallback.length == fallback.length &&
          _sameFamilies(other.fallback, fallback);

  @override
  int get hashCode => Object.hash(family, Object.hashAll(fallback));

  static bool _sameFamilies(List<String> left, List<String> right) {
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

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
///
/// The interface baseline is the platform's own family. A client that has
/// installed no font resource — a first launch, or any launch without network —
/// renders every role from faces the operating system already owns, and the
/// per-context Chinese faces head the chain so Chinese interface text has a
/// platform owner before the bundled family is consulted.
abstract final class LicoTypography {
  /// The bundled monospace family. It ships with the client and carries the
  /// commands, paths, identifiers and numeric readouts.
  static const String monoFamily = 'Geist Mono';

  /// The bundled interface family.
  ///
  /// It is no longer the baseline: a preference that names it makes it the
  /// first family, and it stays in [sansFallback] to cover glyphs no platform
  /// face supplies.
  static const String bundledSansFamily = 'Geist Sans';

  /// The interface family chain, most platform-specific first.
  ///
  /// The head of each group is the family the owning platform renders its own
  /// interface with. The bundled face comes last, so nothing bundled is
  /// required for the interface to render.
  static const List<String> sansFallback = <String>[
    // macOS and iOS, then their Chinese faces.
    '.AppleSystemUIFont',
    'SF Pro Text',
    'SF Pro Display',
    'Helvetica Neue',
    'PingFang SC',
    'Hiragino Sans GB',
    // Windows, then its Chinese face.
    'Segoe UI Variable Text',
    'Segoe UI',
    'Microsoft YaHei',
    // Android, Fuchsia and Linux, then their Chinese faces.
    'Roboto',
    'Ubuntu',
    'Cantarell',
    'Noto Sans',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'DejaVu Sans',
    // Glyphs no platform face supplies still resolve inside the client.
    bundledSansFamily,
    'sans-serif',
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

  /// The interface family the platform itself owns.
  static String sansFamilyFor(TargetPlatform platform) => switch (platform) {
    TargetPlatform.macOS || TargetPlatform.iOS => '.AppleSystemUIFont',
    TargetPlatform.windows => 'Segoe UI Variable Text',
    TargetPlatform.android || TargetPlatform.fuchsia => 'Roboto',
    TargetPlatform.linux => 'Ubuntu',
  };

  /// The interface family of the platform this build is running on.
  static String get platformSansFamily => sansFamilyFor(defaultTargetPlatform);

  /// Resolves an appearance font preference into the family chain a theme uses.
  ///
  /// A preference that names no family keeps the preset's declared family, and
  /// when the preset declares none either — which is what the built-in presets
  /// do — the platform's own face heads the chain. A named preference puts that
  /// family first and keeps the platform chain behind it, so a family that is
  /// not installed on this machine still renders in the system face instead of
  /// an empty style.
  static LicoFontSelection resolveFont(
    String preference, {
    String? presetFamily,
    TargetPlatform? platform,
  }) {
    final resolvedPlatform = platform ?? defaultTargetPlatform;
    final named = LicoFontPreference.namesFamily(preference)
        ? preference.trim()
        : presetFamily;
    return LicoFontSelection(
      family: named ?? sansFamilyFor(resolvedPlatform),
      fallback: sansFallback,
    );
  }

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
  static TextStyle eyebrow({required Color color, String? fontFamily}) {
    return TextStyle(
      fontFamily: fontFamily ?? platformSansFamily,
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
  static TextStyle actionLabel({required Color color, String? fontFamily}) {
    return TextStyle(
      fontFamily: fontFamily ?? platformSansFamily,
      fontFamilyFallback: sansFallback,
      color: color,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.3,
      letterSpacing: 0.1,
    );
  }

  /// The style for a large metric value in a monitoring tile.
  static TextStyle metric({
    required Color color,
    double fontSize = 24,
    String? fontFamily,
  }) {
    return TextStyle(
      fontFamily: fontFamily ?? platformSansFamily,
      fontFamilyFallback: sansFallback,
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.1,
      letterSpacing: -0.4,
      fontFeatures: tabular,
    );
  }

  /// Builds the application text theme from one resolved font family.
  ///
  /// The scale steps by roughly 1.2 between adjacent levels
  /// (10 → 11 → 12 → 13 → 14 → 15 → 18 → 20 → 24 → 28). Negative tracking on
  /// the large sizes counteracts the optical looseness of big text; positive
  /// tracking on the small sizes keeps them legible.
  static TextTheme textTheme({
    required Color text,
    required Color textSecondary,
    required Color textMuted,
    required String fontFamily,
    List<String> fontFamilyFallback = sansFallback,
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
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
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
