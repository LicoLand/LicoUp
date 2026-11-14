import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_galaxy.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground_scope.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// The single dispatch point for the preset's ambient window-ground effect.
///
/// Mounts the layer matching `LicoThemeColors.ambientEffect` — [LicoGalaxy]
/// for `starfield`, nothing otherwise — so every ground site reaches the
/// effect through one widget and a hot-loaded preset change retargets all
/// of them at once. `waffle` stays reserved for the upcoming cream-waffle
/// ambient; until that design lands it renders no layer and the ground
/// stays a solid cream.
final class LicoAmbientLayer extends StatelessWidget {
  const LicoAmbientLayer({super.key, this.site});

  /// The owning ground's ambient site: shared pointer input, registered
  /// glass regions and the ground's render box. Null renders the effect
  /// without interaction — for tests and ungrounded mounts.
  final LicoWindowGroundSite? site;

  @override
  Widget build(BuildContext context) {
    final effect =
        Theme.of(context).extension<LicoThemeColors>()?.ambientEffect ??
        LicoAmbientEffect.none;
    return switch (effect) {
      LicoAmbientEffect.starfield => LicoGalaxy(site: site),
      LicoAmbientEffect.waffle => const SizedBox.shrink(),
      LicoAmbientEffect.none => const SizedBox.shrink(),
    };
  }
}
