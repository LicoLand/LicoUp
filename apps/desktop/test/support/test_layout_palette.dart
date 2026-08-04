import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';

/// The shared layout palette for widget tests.
///
/// Derived from a real built-in preset through the production projection, so a
/// role added to [LicoThemeColors] cannot be missed here. Fixtures previously
/// hand-enumerated their own palettes, which is how they drifted out of sync
/// with the production role set.
final LayoutPalette testLayoutPalette = layoutPaletteFromColors(
  licoColorsFor(AppearancePresetIds.licoSodaLight),
);

/// The dark counterpart, for tests that assert dark-mode behavior.
final LayoutPalette testLayoutPaletteDark = layoutPaletteFromColors(
  licoColorsFor(AppearancePresetIds.licoSoda),
);

/// A palette with a deliberately distinct background, for tests that need two
/// palettes to compare unequal.
final LayoutPalette testLayoutPaletteAlternate = layoutPaletteFromColors(
  licoColorsFor(AppearancePresetIds.licoSodaLight).copyWith(
    background: const Color(0xFFFFEEDD),
  ),
);
