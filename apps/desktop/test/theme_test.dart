import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/appearance/appearance_projection_adapter.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed presets only. `default-system` has no tokens of its own; it resolves
/// to one of these, so asserting on it would double-count.
Iterable<AppearancePresetConfig> get _fixedPresets =>
    builtInAppearancePresetConfigs.where(
      (preset) => preset.mode != AppearancePresetMode.system,
    );

void main() {
  test('appearance projection adapter preserves theme pixels', () {
    final projected = _appearanceProjection();
    final adapted = appearancePresetConfigsFromProjection(projected);

    expect(adapted.map((preset) => preset.id), AppearancePresetIds.builtIn);
    for (final brightness in Brightness.values) {
      final expected = buildLicoTheme(
        presetId: projected.presetId,
        platformBrightness: brightness,
      );
      final actual = buildLicoTheme(
        presetId: projected.presetId,
        presets: adapted,
        platformBrightness: brightness,
      );
      expect(actual.colorScheme, expected.colorScheme);
      expect(actual.scaffoldBackgroundColor, expected.scaffoldBackgroundColor);
    }
  });

  test('buildLicoTheme applies every appearance preset', () {
    for (final preset in builtInAppearancePresetConfigs) {
      final platformBrightness = preset.id == AppearancePresetIds.defaultSystem
          ? Brightness.dark
          : Brightness.light;
      final colors = licoColorsFor(
        preset.id,
        platformBrightness: platformBrightness,
      );
      final theme = buildLicoTheme(
        presetId: preset.id,
        platformBrightness: platformBrightness,
      );

      expect(theme.scaffoldBackgroundColor, colors.background);
      expect(theme.textTheme.bodyLarge?.color, colors.text);
      expect(theme.colorScheme.surface, colors.surface);
      expect(theme.colorScheme.primary, colors.primary);
      // Secondary carries the interaction color so Material components that
      // reach for `secondary` land on the accent rather than on lemon.
      expect(theme.colorScheme.secondary, colors.accent);
      expect(theme.colorScheme.error, colors.error);
      expect(theme.colorScheme.onSurface, colors.text);
      expect(theme.colorScheme.surfaceContainerHighest, colors.surfaceRaised);
      final extension = theme.extension<LicoThemeColors>();
      expect(extension?.background, colors.background);
      expect(extension?.primary, colors.primary);
      expect(extension?.textOnPrimary, colors.textOnPrimary);
      expect(extension?.accent, colors.accent);

      final cardTheme = theme.cardTheme;
      expect(cardTheme.shape, isA<RoundedRectangleBorder>());
      expect(cardTheme.elevation, 0);
      expect(cardTheme.color, colors.surface);

      // Surfaces and rims must come from the neutral ramp, never from a
      // white/black alpha wash that ignores the preset's own background.
      final inputTheme = theme.inputDecorationTheme;
      expect(inputTheme.filled, isTrue);
      expect(inputTheme.fillColor, colors.surfaceLow);
      expect(
        theme.textSelectionTheme.cursorColor,
        colors.accent,
        reason: 'selection is an interaction, so it uses the accent',
      );
    }
  });

  group('color role constraints', () {
    // Body text and any color used as text must clear WCAG AA.
    const bodyText = 4.5;
    // Non-text graphics: indicators, rims that carry meaning (WCAG 1.4.11).
    const graphic = 3.0;

    test('text roles stay readable on every surface they sit on', () {
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        for (final surface in <(String, Color)>[
          ('bg-base', c.background),
          ('bg-surface', c.surface),
          ('bg-subtle', c.surfaceLow),
          ('bg-raised', c.surfaceRaised),
        ]) {
          for (final text in <(String, Color)>[
            ('text-primary', c.text),
            ('text-secondary', c.textSecondary),
            ('text-muted', c.textMuted),
          ]) {
            expect(
              _contrast(text.$2, surface.$2),
              greaterThanOrEqualTo(bodyText),
              reason: '${preset.id}: ${text.$1} on ${surface.$1}',
            );
          }
        }
      }
    });

    test('ink on a filled role clears AA', () {
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        expect(
          _contrast(c.textOnPrimary, c.primary),
          greaterThanOrEqualTo(bodyText),
          reason: '${preset.id}: text-on-brand on brand',
        );
        expect(
          _contrast(c.textOnAccent, c.accent),
          greaterThanOrEqualTo(bodyText),
          reason: '${preset.id}: text-on-accent on accent',
        );
        for (final tone in <(String, Color)>[
          ('brand-subtle', c.brandSurface),
          ('accent-surface', c.accentSurface),
        ]) {
          expect(
            _contrast(c.text, tone.$2),
            greaterThanOrEqualTo(bodyText),
            reason: '${preset.id}: text-primary on ${tone.$1}',
          );
        }
      }
    });

    test('the accent is safe as interactive text in both modes', () {
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        expect(
          _contrast(c.accent, c.surface),
          greaterThanOrEqualTo(bodyText),
          reason: '${preset.id}: accent must be legible as link text',
        );
        expect(
          _contrast(c.accentStrong, c.surface),
          greaterThanOrEqualTo(bodyText),
          reason: '${preset.id}: accent-strong must be legible as link text',
        );
      }
    });

    test('semantic signals clear AA as text', () {
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        for (final signal in <(String, Color)>[
          ('success', c.success),
          ('warning', c.warning),
          ('danger', c.error),
        ]) {
          expect(
            _contrast(signal.$2, c.surface),
            greaterThanOrEqualTo(bodyText),
            reason: '${preset.id}: ${signal.$1} on bg-surface',
          );
        }
      }
    });

    test('brand carries strokes through brand-strong, never as text', () {
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        // A pale lemon fill cannot reach 3:1 against white, which is exactly
        // why the brand is a fill-and-mark role. Every lemon stroke and
        // indicator uses brand-strong, which must clear the graphic threshold.
        expect(
          _contrast(c.primaryStrong, c.surface),
          greaterThanOrEqualTo(graphic),
          reason: '${preset.id}: brand-strong must be visible as a mark',
        );
        // Because the fill itself can be near-invisible against the surface,
        // its hairline is mandatory and must itself be discernible.
        expect(
          _contrast(c.brandBorder, c.surface),
          greaterThanOrEqualTo(1.8),
          reason: '${preset.id}: brand fills require a visible hairline',
        );
      }
    });

    test('separators are discernible without shouting', () {
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        expect(
          _contrast(c.line, c.surface),
          greaterThanOrEqualTo(1.25),
          reason: '${preset.id}: border-subtle must be visible',
        );
        expect(
          _contrast(c.lineStrong, c.surface),
          greaterThanOrEqualTo(2.0),
          reason: '${preset.id}: border-strong must read as emphasis',
        );
      }
    });

    test('neutral surface steps are perceptually distinct', () {
      // Contrast ratio compresses badly near black, so surface separation is
      // measured in CIE L* instead. Production dark systems step by roughly
      // 2.3-7.4 L*; 3.0 is the floor for a step that reads on a good display.
      const minimumStep = 3.0;
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        final ramp = <(String, Color)>[
          ('bg-inset', c.surfaceSunken),
          ('bg-base', c.background),
          ('bg-surface', c.surface),
          ('bg-subtle', c.surfaceLow),
          ('bg-raised', c.surfaceRaised),
        ];
        for (var index = 0; index < ramp.length - 1; index += 1) {
          final from = ramp[index];
          final to = ramp[index + 1];
          // Light mode expresses its top step with shadow rather than tone, so
          // bg-raised is allowed to match bg-surface there.
          if (!c.isDark && to.$1 == 'bg-raised') {
            continue;
          }
          expect(
            (_lstar(to.$2) - _lstar(from.$2)).abs(),
            greaterThanOrEqualTo(minimumStep),
            reason: '${preset.id}: ${from.$1} -> ${to.$1} step too small',
          );
        }
      }
    });

    test('neutrals stay clean instead of dusty', () {
      // The first attempt at this palette put the neutral ramp at OKLCH chroma
      // 0.019-0.026, which is the dusty-slate band, and the whole interface
      // read as grey haze. Production dark systems sit near 0.004 and the
      // brief's own graphite reference is 0.013. This is the gate that would
      // have caught it.
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        final neutrals = <String, Color>{
          'bg-inset': c.surfaceSunken,
          'bg-base': c.background,
          'bg-surface': c.surface,
          'bg-subtle': c.surfaceLow,
          'bg-raised': c.surfaceRaised,
          'border-subtle': c.line,
          'border-strong': c.lineStrong,
          'text-secondary': c.textSecondary,
          'text-muted': c.textMuted,
        };
        neutrals.forEach((name, color) {
          expect(
            _chroma(color),
            lessThanOrEqualTo(0.013),
            reason: '${preset.id}: $name is too chromatic to read as neutral',
          );
        });
      }
    });

    test('brand and accent are vivid, not muted', () {
      // A brand that is scarce *and* desaturated is invisible. The reference
      // point is the brief's own electric yellow #D9F14A at chroma 0.1855.
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        expect(
          _chroma(c.primary),
          greaterThanOrEqualTo(0.185),
          reason: '${preset.id}: brand must be at least as vivid as #D9F14A',
        );
        expect(
          _chroma(c.accent),
          greaterThanOrEqualTo(0.090),
          reason: '${preset.id}: accent must carry real chroma',
        );
      }
    });

    test('the brand wash is a tint, not mud', () {
      // Hand-picking a dark lemon tint produced olive mud (#2a2f12, chroma
      // 0.047). The wash is now computed at low alpha and must stay close to
      // neutral so it reads as a warm surface rather than a colour mistake.
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        expect(
          _chroma(c.brandSurface),
          lessThanOrEqualTo(c.isDark ? 0.030 : 0.075),
          reason: '${preset.id}: brand-subtle is muddy',
        );
      }
    });

    test('glow roles are translucent so they can layer as light', () {
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        for (final glow in <String, Color>{
          'brand-glow': c.brandGlow,
          'accent-glow': c.accentGlow,
        }.entries) {
          expect(glow.value.a, greaterThan(0.0), reason: glow.key);
          expect(glow.value.a, lessThan(1.0), reason: glow.key);
        }
      }
    });

    test('every fixed preset resolves a distinct brand and accent hue', () {
      for (final preset in _fixedPresets) {
        final c = licoColorsFor(preset.id);
        expect(
          c.primary,
          isNot(c.accent),
          reason: '${preset.id}: brand and accent must not collapse',
        );
        expect(
          c.warning,
          isNot(c.primary),
          reason: '${preset.id}: warning must not be mistaken for the brand',
        );
      }
    });
  });

  test('no ColorScheme role falls outside the palette', () {
    // `copyWith` on a Material baseline previously left twelve roles at
    // Material's own palette. Widgets reaching for them rendered teal #03dac6
    // and purple #bb86fc, producing a refresh control drawn as a mint circle
    // with a pink glyph. An incomplete ColorScheme is a colour leak.
    for (final preset in _fixedPresets) {
      final theme = buildLicoTheme(presetId: preset.id);
      final colors = theme.extension<LicoThemeColors>()!;
      final allowed = <int>{
        for (final color in <Color>[
          colors.background,
          colors.surface,
          colors.surfaceLow,
          colors.surfaceRaised,
          colors.surfaceSunken,
          colors.line,
          colors.lineStrong,
          colors.text,
          colors.textSecondary,
          colors.textMuted,
          colors.textDisabled,
          colors.primary,
          colors.primaryStrong,
          colors.brandSurface,
          colors.brandBorder,
          colors.textOnPrimary,
          colors.accent,
          colors.accentStrong,
          colors.accentSurface,
          colors.accentBorder,
          colors.textOnAccent,
          colors.success,
          colors.warning,
          colors.error,
        ])
          color.toARGB32(),
        // Absolutes the scale is allowed to use directly.
        0xFFFFFFFF,
        0xFF000000,
        0x00000000,
      };
      final scheme = theme.colorScheme;
      final roles = <String, Color>{
        'primary': scheme.primary,
        'onPrimary': scheme.onPrimary,
        'primaryContainer': scheme.primaryContainer,
        'onPrimaryContainer': scheme.onPrimaryContainer,
        'primaryFixed': scheme.primaryFixed,
        'primaryFixedDim': scheme.primaryFixedDim,
        'onPrimaryFixed': scheme.onPrimaryFixed,
        'onPrimaryFixedVariant': scheme.onPrimaryFixedVariant,
        'secondary': scheme.secondary,
        'onSecondary': scheme.onSecondary,
        'secondaryContainer': scheme.secondaryContainer,
        'onSecondaryContainer': scheme.onSecondaryContainer,
        'secondaryFixed': scheme.secondaryFixed,
        'secondaryFixedDim': scheme.secondaryFixedDim,
        'onSecondaryFixed': scheme.onSecondaryFixed,
        'onSecondaryFixedVariant': scheme.onSecondaryFixedVariant,
        'tertiary': scheme.tertiary,
        'onTertiary': scheme.onTertiary,
        'tertiaryContainer': scheme.tertiaryContainer,
        'onTertiaryContainer': scheme.onTertiaryContainer,
        'tertiaryFixed': scheme.tertiaryFixed,
        'tertiaryFixedDim': scheme.tertiaryFixedDim,
        'onTertiaryFixed': scheme.onTertiaryFixed,
        'onTertiaryFixedVariant': scheme.onTertiaryFixedVariant,
        'error': scheme.error,
        'onError': scheme.onError,
        'errorContainer': scheme.errorContainer,
        'onErrorContainer': scheme.onErrorContainer,
        'surface': scheme.surface,
        'onSurface': scheme.onSurface,
        'onSurfaceVariant': scheme.onSurfaceVariant,
        'surfaceDim': scheme.surfaceDim,
        'surfaceBright': scheme.surfaceBright,
        'surfaceContainerLowest': scheme.surfaceContainerLowest,
        'surfaceContainerLow': scheme.surfaceContainerLow,
        'surfaceContainer': scheme.surfaceContainer,
        'surfaceContainerHigh': scheme.surfaceContainerHigh,
        'surfaceContainerHighest': scheme.surfaceContainerHighest,
        'inverseSurface': scheme.inverseSurface,
        'onInverseSurface': scheme.onInverseSurface,
        'inversePrimary': scheme.inversePrimary,
        'outline': scheme.outline,
        'outlineVariant': scheme.outlineVariant,
        'surfaceTint': scheme.surfaceTint,
        'shadow': scheme.shadow,
        'scrim': scheme.scrim,
      };
      final leaks = <String>[];
      roles.forEach((name, color) {
        if (!allowed.contains(color.toARGB32())) {
          leaks.add(
            '$name = #${color.toARGB32().toRadixString(16).padLeft(8, '0')}',
          );
        }
      });
      expect(
        leaks,
        isEmpty,
        reason: '${preset.id} leaked: ${leaks.join(', ')}',
      );
    }
  });

  test('following the system appearance never changes the brand hue', () {
    // The previous built-ins paired a yellow dark brand with a cobalt light
    // brand, so switching the OS appearance silently rebranded the client.
    final light = licoColorsFor(
      AppearancePresetIds.defaultSystem,
      platformBrightness: Brightness.light,
    );
    final dark = licoColorsFor(
      AppearancePresetIds.defaultSystem,
      platformBrightness: Brightness.dark,
    );
    expect(_hue(light.primary), closeTo(_hue(dark.primary), 24));
    expect(_hue(light.accent), closeTo(_hue(dark.accent), 24));
  });

  test('every built-in light preset is directly selectable', () {
    // A light theme nobody can choose is not a light theme.
    expect(AppearancePresetIds.resolutionOnly, isEmpty);
    expect(
      _fixedPresets.map((preset) => preset.mode).toSet(),
      {AppearancePresetMode.light, AppearancePresetMode.dark},
      reason: 'both modes must be offered as first-class choices',
    );
  });

  test('day night brightness helpers map to fixed presets', () {
    expect(
      appearancePresetIdForBrightness(false),
      AppearancePresetIds.licoSodaLight,
    );
    expect(appearancePresetIdForBrightness(true), AppearancePresetIds.licoSoda);
    expect(
      isResolvedAppearanceDark(
        AppearancePresetIds.defaultSystem,
        builtInAppearancePresetConfigs,
        Brightness.light,
      ),
      isFalse,
    );
    expect(
      isResolvedAppearanceDark(
        AppearancePresetIds.defaultSystem,
        builtInAppearancePresetConfigs,
        Brightness.dark,
      ),
      isTrue,
    );
  });

  test('appearance preset picker filters by resolved brightness', () {
    final darkPresets = selectableAppearancePresetsForBrightness(
      builtInAppearancePresetConfigs,
      true,
    );
    expect(darkPresets.map((preset) => preset.id), [
      AppearancePresetIds.licoSoda,
    ]);

    final lightPresets = selectableAppearancePresetsForBrightness(
      builtInAppearancePresetConfigs,
      false,
    );
    expect(lightPresets.map((preset) => preset.id), [
      AppearancePresetIds.licoSodaLight,
    ]);
  });

  test('brightness selection maps to persisted preset ids', () {
    expect(
      appearanceBrightnessSelectionFor(
        AppearancePresetIds.defaultSystem,
        builtInAppearancePresetConfigs,
      ),
      AppearanceBrightnessSelection.system,
    );
    expect(
      appearanceBrightnessSelectionFor(
        AppearancePresetIds.licoSodaLight,
        builtInAppearancePresetConfigs,
      ),
      AppearanceBrightnessSelection.light,
    );
    expect(
      appearancePresetIdForBrightnessSelection(
        AppearanceBrightnessSelection.system,
        AppearancePresetIds.licoSodaLight,
        builtInAppearancePresetConfigs,
      ),
      AppearancePresetIds.defaultSystem,
    );
    expect(
      appearancePresetIdForBrightnessSelection(
        AppearanceBrightnessSelection.light,
        AppearancePresetIds.defaultSystem,
        builtInAppearancePresetConfigs,
      ),
      AppearancePresetIds.licoSodaLight,
    );
    expect(
      appearancePresetIdForBrightnessSelection(
        AppearanceBrightnessSelection.dark,
        AppearancePresetIds.licoSodaLight,
        builtInAppearancePresetConfigs,
      ),
      AppearancePresetIds.licoSoda,
    );
    expect(
      appearancePresetIdForBrightnessSelection(
        AppearanceBrightnessSelection.light,
        AppearancePresetIds.licoSoda,
        builtInAppearancePresetConfigs,
      ),
      AppearancePresetIds.licoSodaLight,
    );
    expect(
      appearancePresetIdForBrightnessSelection(
        AppearanceBrightnessSelection.dark,
        AppearancePresetIds.licoSoda,
        builtInAppearancePresetConfigs,
      ),
      AppearancePresetIds.licoSoda,
    );
  });

  test('built-in preset labels use LicoUp product names', () {
    final dark = findAppearancePresetConfig(
      AppearancePresetIds.licoSoda,
      builtInAppearancePresetConfigs,
    );
    final light = findAppearancePresetConfig(
      AppearancePresetIds.licoSodaLight,
      builtInAppearancePresetConfigs,
    );
    expect(dark.labelFor('en'), 'LicoUp Dark');
    expect(dark.labelFor('zh-CN'), 'LicoUp 暗黑');
    expect(light.labelFor('en'), 'LicoUp Light');
    expect(light.labelFor('zh-CN'), 'LicoUp 明亮');
  });

  test('default-system resolves to configured light and dark presets', () {
    final defaultSystem = findAppearancePresetConfig(
      AppearancePresetIds.defaultSystem,
      builtInAppearancePresetConfigs,
    );
    expect(
      licoColorsFor(
        AppearancePresetIds.defaultSystem,
        platformBrightness: Brightness.light,
      ).primary,
      licoColorsFor(defaultSystem.lightPresetId!).primary,
    );
    expect(
      licoColorsFor(
        AppearancePresetIds.defaultSystem,
        platformBrightness: Brightness.dark,
      ).primary,
      licoColorsFor(defaultSystem.darkPresetId!).primary,
    );
  });

  test('a schema v1 preset still loads and derives the newer roles', () {
    // Presets authored before appearance-preset-2 must keep working: the
    // runtime derive layer fills in the roles they never declared.
    final legacy = AppearancePresetConfig.fromJson({
      'schemaVersion': 1,
      'id': 'agent-preview',
      'label': {'en': 'Agent Preview', 'zh-CN': '智能体预览'},
      'mode': 'light',
      'tokens': {
        'bg-base': '#fff7ed',
        'bg-surface': '#ffffff',
        'bg-subtle': '#ffedd5',
        'text-primary': '#1c1917',
        'text-muted': '#78716c',
        'text-on-brand': '#ffffff',
        'brand': '#7c3aed',
        'brand-strong': '#5b21b6',
        'brand-subtle': '#ede9fe',
        'success': '#15803d',
        'warning': '#b45309',
        'danger': '#b91c1c',
      },
    });
    final presets = mergeAppearancePresetConfigs([legacy]);
    final colors = licoColorsFor('agent-preview', presets: presets);
    final theme = buildLicoTheme(presetId: 'agent-preview', presets: presets);

    expect(themeModeForAppearance('agent-preview', presets), ThemeMode.light);
    expect(colors.background, const Color(0xFFFFF7ED));
    expect(colors.primary, const Color(0xFF7C3AED));
    expect(theme.colorScheme.primary, const Color(0xFF7C3AED));
    // Roles the legacy preset never declared still resolve to real colors.
    expect(colors.accent, isNot(colors.primary));
    expect(colors.surfaceRaised.a, 1.0);
    expect(colors.hoverOverlay.a, lessThan(1.0));
    expect(colors.brandBorder.a, 1.0);
  });

  test('a preset declaring schema v2 must supply the newer roles itself', () {
    final result = validateAppearancePresetConfig({
      'schemaVersion': 2,
      'id': 'incomplete-v2',
      'label': {'en': 'Incomplete', 'zh-CN': '不完整'},
      'mode': 'dark',
      'tokens': {
        'bg-base': '#000000',
        'bg-surface': '#111111',
        'bg-subtle': '#222222',
        'text-primary': '#ffffff',
        'text-muted': '#aaaaaa',
        'text-on-brand': '#000000',
        'brand': '#e3f26b',
        'brand-strong': '#effa96',
        'brand-subtle': '#2a2f12',
        'success': '#4ed9a4',
        'warning': '#f5a63c',
        'danger': '#ff6b5f',
      },
    });
    expect(result.ok, isFalse);
    expect(result.errors.join('; '), contains('accent'));
  });

  test('rgba token values resolve to a translucent color', () {
    // The overlay roles are authored as rgba(), which a hex-only parser would
    // have thrown on.
    final colors = licoColorsFor(AppearancePresetIds.licoSoda);
    expect(colors.hoverOverlay.a, greaterThan(0.0));
    expect(colors.hoverOverlay.a, lessThan(1.0));
    expect(colors.pressedOverlay.a, greaterThan(colors.hoverOverlay.a));
  });

  group('concentric radius', () {
    test('a nested control shares its container corner center', () {
      expect(
        LicoRadius.composerControl,
        LicoRadius.composerField - LicoRadius.composerInset,
      );
      expect(
        LicoRadius.isConcentric(
          LicoRadius.composerControl,
          LicoRadius.composerField,
          LicoRadius.composerInset,
        ),
        isTrue,
      );
    });

    test('a gap wider than the container radius yields a square corner', () {
      expect(LicoRadius.nested(4, 10), 0);
    });

    test('enclosing and nested are inverses', () {
      expect(LicoRadius.nested(LicoRadius.enclosing(6, 4), 4), 6);
    });
  });
}

AppearanceProjection _appearanceProjection() => AppearanceProjection(
  presetId: AppearancePresetIds.defaultSystem,
  presets: builtInAppearancePresetConfigs.map(
    (preset) => AppearancePresetProjection(
      id: preset.id,
      label: preset.labelFor(),
      modeId: preset.mode.id,
      tokens: preset.tokens.entries.map(
        (token) =>
            AppearanceTokenProjection(name: token.key, value: token.value),
      ),
    ),
  ),
);

double _contrast(Color a, Color b) {
  final aLum = a.computeLuminance();
  final bLum = b.computeLuminance();
  final lighter = math.max(aLum, bLum);
  final darker = math.min(aLum, bLum);
  return (lighter + 0.05) / (darker + 0.05);
}

/// CIE L* lightness, for measuring perceptual surface separation.
double _lstar(Color color) {
  final y = color.computeLuminance();
  return y <= 216 / 24389 ? y * (24389 / 27) : math.pow(y, 1 / 3) * 116 - 16;
}

/// Hue angle in degrees, for asserting two palettes share a brand family.
double _hue(Color color) {
  return HSLColor.fromColor(color).hue;
}

/// OKLCH chroma: how colourful a value is, independent of how light it is.
///
/// This is the measure that separates a clean neutral from a dusty one, and a
/// vivid accent from a muted one. Saturation in HSL cannot do this job because
/// it reports near-black and near-white values as highly saturated.
double _chroma(Color color) {
  double toLinear(double channel) {
    return channel <= 0.04045
        ? channel / 12.92
        : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  }

  final r = toLinear(color.r);
  final g = toLinear(color.g);
  final b = toLinear(color.b);
  final l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  final m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  final s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
  final lRoot = math.pow(l, 1 / 3).toDouble();
  final mRoot = math.pow(m, 1 / 3).toDouble();
  final sRoot = math.pow(s, 1 / 3).toDouble();
  final a = 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot;
  final bAxis =
      0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot;
  return math.sqrt(a * a + bAxis * bAxis);
}
