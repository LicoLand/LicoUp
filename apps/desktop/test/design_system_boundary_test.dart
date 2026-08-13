import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Enforces the design-system rules that are easy to state and easy to break.
///
/// Each rule here exists because the client already regressed on it once. A
/// review comment does not survive; a test does.
void main() {
  final frontend = Directory('lib/src/frontend');

  test('shared UI does not invent white or black alpha washes', () {
    // Surfaces, rims, and state washes must come from color roles. Deriving
    // them from Colors.white/black means a preset whose background is not near
    // the expected brightness gets a foreign haze laid over it, and it is why
    // every control used to look identical.
    const allowed = <String>{
      // Paints the fixed brand mark, which is deliberately palette-independent.
      'licoup_logo.dart',
      // Reproduces the macOS system menu material, which is specified in
      // absolute colors by the platform.
      'apple_popup_select.dart',
      // Shadows are black by definition; the elevation scale owns them.
      'lico_elevation.dart',
    };
    final offenders = <String>[];
    for (final file in _dartFiles(Directory('lib/src/frontend/shared/ui'))) {
      final name = file.uri.pathSegments.last;
      if (allowed.contains(name)) {
        continue;
      }
      final source = file.readAsStringSync();
      for (final match in _whiteBlackAlpha.allMatches(source)) {
        offenders.add('$name: ${match.group(0)}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use hoverOverlay / pressedOverlay / surfaceLow / surfaceRaised / '
          'line / lineStrong instead of a hardcoded alpha wash.\n'
          '${offenders.join('\n')}',
    );
  });

  test('retired color roles are gone from the whole frontend', () {
    // surfaceHigh/surfaceHighest were brand tints masquerading as elevation
    // steps, primaryFixed duplicated surfaceHigh, and info doubled as the
    // interaction color. Reintroducing any of them re-creates the flatness.
    final offenders = <String>[];
    for (final file in _dartFiles(frontend)) {
      final source = file.readAsStringSync();
      for (final match in _retiredRoles.allMatches(source)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('shared UI takes every duration from the motion scale', () {
    // The shared component layer is the reusable surface, so it holds the
    // strict rule. LicoMotion owns the scale; lico_motion.dart defines it.
    final offenders = <String>[];
    for (final file in _dartFiles(Directory('lib/src/frontend/shared/ui'))) {
      if (file.uri.pathSegments.last == 'lico_motion.dart') {
        continue;
      }
      for (final match in _durationLiteral.allMatches(
        file.readAsStringSync(),
      )) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use LicoMotion.micro / short / medium / long / loopShort / loopLong '
          'and route through context.motion(...).\n${offenders.join('\n')}',
    );
  });

  test('feature-layer motion debt only shrinks', () {
    // 44 inline duration literals remain outside the shared layer. Migrating
    // them all in one sweep would be a blind edit across surfaces that have
    // not been reviewed, so this is a ratchet instead of a hard rule: the
    // count may fall, never rise. Lower the budget as batches land.
    const budget = 44;
    final offenders = <String>[];
    for (final file in _dartFiles(frontend)) {
      final path = file.path;
      if (path.contains('/shared/ui/')) {
        continue;
      }
      final source = file.readAsStringSync();
      for (final match in _durationLiteral.allMatches(source)) {
        // A layout profile's token file legitimately *defines* its
        // motionDuration; that declaration is the token, not a stray literal.
        final lineStart = source.lastIndexOf('\n', match.start) + 1;
        if (source
            .substring(lineStart, match.end)
            .contains('motionDuration:')) {
          continue;
        }
        offenders.add('$path: ${match.group(0)}');
      }
    }
    expect(
      offenders.length,
      lessThanOrEqualTo(budget),
      reason:
          'New inline durations are not allowed. Use LicoMotion.\n'
          '${offenders.join('\n')}',
    );
  });

  test('the brand is never a glyph or text colour', () {
    // The rule "lemon is never a text colour" was written in the design doc
    // and asserted only against the *role definitions*. Thirty components
    // still passed `colors.primary` straight into an Icon or TextStyle, which
    // renders at 1.40:1 on a white surface — completely illegible. A palette
    // can be mathematically perfect and the app still unreadable, so the rule
    // has to be enforced at the point of use.
    //
    // `primaryStrong` is permitted for non-text graphics because it is the
    // variant guaranteed to clear 3:1 against the surface in both modes.
    final offenders = <String>[];
    for (final file in _dartFiles(frontend)) {
      final lines = file.readAsStringSync().split('\n');
      for (var index = 0; index < lines.length; index += 1) {
        final line = lines[index];
        if (!_brandForeground.hasMatch(line)) {
          continue;
        }
        // Look back a few lines to see what is being coloured.
        final context = lines
            .sublist(index < 4 ? 0 : index - 4, index + 1)
            .join('\n');
        final isGlyphOrText =
            RegExp(
              r'Icon\(|IconTheme|TextStyle\(|TextSpan\(',
            ).hasMatch(context) ||
            RegExp(r'(foregroundColor|iconColor):').hasMatch(line);
        if (isGlyphOrText) {
          offenders.add('${file.path}:${index + 1}: ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Brand is a fill-and-mark role. Use accent/accentStrong for '
          'interactive glyphs and text, textSecondary for decorative icons, '
          'or textOnPrimary when the glyph sits on a brand fill.\n'
          '${offenders.join('\n')}',
    );
  });

  test('feature-layer white/black alpha debt only shrinks', () {
    // The shared layer rejects invented white/black alpha washes outright
    // (see the first test), but the feature layer still carries 74 of them —
    // hover washes and rims that ignore the preset's own hoverOverlay/line
    // roles and therefore will not follow a skin change. Replacing them all
    // in one sweep would be a blind edit, so this is a ratchet: the count may
    // fall, never rise. New state washes must use hoverOverlay /
    // pressedOverlay / selectedSurface / line / lineStrong.
    const budget = 74;
    final offenders = <String>[];
    for (final file in _dartFiles(frontend)) {
      final path = file.path;
      if (path.contains('/shared/ui/')) {
        continue;
      }
      final source = file.readAsStringSync();
      for (final match in _whiteBlackAlpha.allMatches(source)) {
        offenders.add('$path: ${match.group(0)}');
      }
    }
    expect(
      offenders.length,
      lessThanOrEqualTo(budget),
      reason:
          'New white/black alpha washes are not allowed. Use the state and '
          'line roles.\n${offenders.join('\n')}',
    );
  });

  test('conversation visual roles preserve their exact channel values', () {
    final dark = licoColorsFor(AppearancePresetIds.licoSoda);
    final light = licoColorsFor(AppearancePresetIds.licoSodaLight);

    expect(
      ConversationVisualTokens.circularIdentityWellFill(dark).toARGB32(),
      Colors.black.toARGB32(),
    );
    expect(
      ConversationVisualTokens.circularIdentityWellFill(light).toARGB32(),
      light.surfaceLow.toARGB32(),
    );
    expect(
      ConversationVisualTokens.groupIdentityMark(dark).toARGB32(),
      dark.primary.toARGB32(),
    );
    expect(
      ConversationVisualTokens.groupIdentityMark(light).toARGB32(),
      light.primary.toARGB32(),
    );
    expect(
      ConversationVisualTokens.quietRowHover(dark).toARGB32(),
      const Color(0x08FFFFFF).toARGB32(),
    );
    expect(
      ConversationVisualTokens.quietRowHover(light).toARGB32(),
      const Color(0x08000000).toARGB32(),
    );
    expect(
      ConversationVisualTokens.selectedOptionFill(dark).toARGB32(),
      const Color(0x0AFFFFFF).toARGB32(),
    );
    expect(
      ConversationVisualTokens.selectedOptionFill(light).toARGB32(),
      const Color(0x08000000).toARGB32(),
    );
    expect(
      ConversationVisualTokens.adaptiveFlywheelStadiumVeil(dark).toARGB32(),
      const Color(0x6E000000).toARGB32(),
    );
    expect(
      ConversationVisualTokens.adaptiveFlywheelStadiumVeil(light).toARGB32(),
      const Color(0x24000000).toARGB32(),
    );
  });

  test('feature-layer radius literal debt only shrinks', () {
    // Outside the shared layer, 36 corners still restate the chip/floating/
    // card values as numeric literals, where a future radius change cannot
    // reach them. The layout layer is exempt: it is forbidden from importing
    // shared/ui and defines its own metrics tokens. A stadium (999) is a
    // shape choice, not a scale step, and is not counted. This is a ratchet:
    // the count may fall, never rise.
    const budget = 36;
    final offenders = <String>[];
    for (final file in _dartFiles(frontend)) {
      final path = file.path;
      if (path.contains('/shared/ui/') || path.contains('/layout/')) {
        continue;
      }
      final source = file.readAsStringSync();
      for (final match in _radiusLiteral.allMatches(source)) {
        if (match.group(1) == '999') {
          continue;
        }
        offenders.add('$path: ${match.group(0)}');
      }
    }
    expect(
      offenders.length,
      lessThanOrEqualTo(budget),
      reason:
          'New numeric corner radii are not allowed. Use LicoRadius.chip / '
          'floating / card / well.\n${offenders.join('\n')}',
    );
  });

  test('the composer send control is a circle', () {
    final source = File(
      'lib/src/frontend/features/agents/ui/agent_conversation_composer.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('LicoIconButtonShape.circle'),
      reason: 'the send control must be a perfect circle',
    );
    expect(
      source,
      isNot(contains('LicoIconButtonShape.concentric')),
      reason: 'the send control must not nest concentrically in the field',
    );
  });

  test('the palette projection is the only place roles are enumerated', () {
    // Every hand-written LayoutPalette(...) is a place a newly added role can
    // be silently dropped. Production and tests share one projection.
    final offenders = <String>[];
    for (final directory in [frontend, Directory('test')]) {
      for (final file in _dartFiles(directory)) {
        final name = file.uri.pathSegments.last;
        if (name == 'layout_palette_projection.dart' ||
            name == 'layout_palette.dart' ||
            name == 'test_layout_palette.dart' ||
            name == 'design_system_boundary_test.dart') {
          continue;
        }
        if (file.readAsStringSync().contains('LayoutPalette(')) {
          offenders.add(file.path);
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use layoutPaletteFromColors(colors) or the shared test fixtures.\n'
          '${offenders.join('\n')}',
    );
  });
}

Iterable<File> _dartFiles(Directory directory) {
  if (!directory.existsSync()) {
    return const <File>[];
  }
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));
}

final _whiteBlackAlpha = RegExp(
  r'Colors\.(white|black)\s*\.\s*with(Alpha|Opacity|Values)\s*\(',
);

final _retiredRoles = RegExp(
  r'\b(colors|palette|extension)\??\.'
  r'(surfaceHigh|surfaceHighest|primaryFixed|info|infoMuted)\b',
);

final _durationLiteral = RegExp(r'Duration\(milliseconds:\s*(\d+)\)');

final _radiusLiteral = RegExp(r'BorderRadius\.circular\((\d+)\)');

/// A bare brand colour, excluding `.withAlpha`/`.withValues` fills and the
/// emphatic `primaryStrong` variant that is safe for non-text graphics.
final _brandForeground = RegExp(
  r'(colors|palette)\.primary\b(?!\s*\.with)(?!Strong)(?!Fixed)',
);
