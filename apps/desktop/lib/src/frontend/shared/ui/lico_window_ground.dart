import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/shared/ui/lico_ambient_interaction.dart';
import 'package:licoup/src/frontend/shared/ui/lico_ambient_layer.dart';
import 'package:licoup/src/frontend/shared/ui/lico_galaxy.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground_scope.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

export 'package:licoup/src/frontend/shared/ui/lico_window_ground_scope.dart'
    show
        LicoGlassRegionRegistry,
        LicoGlassRegionSurface,
        LicoWindowGroundScope,
        LicoWindowGroundSite;

/// The window-ground layer the conversation content sits on.
///
/// Paints [color] as the fill, the preset's ambient effect ([LicoAmbientLayer])
/// on that fill, and [child] above both, so the effect reads through wherever
/// the content leaves the ground transparent and stays covered by opaque
/// surfaces. The fill stays a sibling behind [child] — never an ancestor —
/// so ink rendering on the shell's Material is unaffected.
///
/// A transparent [color] paints no fill — the lower ground shows through —
/// but the ambient effect still mounts here: the effect belongs to the
/// conversation ground, not to whichever layer happens to paint the fill.
///
/// The outermost ground owns the preset's ambient effect. A ground that finds
/// an ancestor [LicoWindowGroundScope] still paints its own [color] fill but
/// mounts no second [LicoAmbientLayer], so nested grounds never paint a
/// second sky; glass regions anywhere below resolve to the owning ground.
///
/// The owning ground also feeds the ambient effect's input: pointer hover
/// reports the cursor position in ground coordinates into
/// [LicoAmbientInteraction]; the interception is not opaque to hit testing.
final class LicoWindowGround extends StatefulWidget {
  const LicoWindowGround({
    super.key,
    required this.color,
    required this.child,
    this.ambient = true,
  });

  final Color color;

  /// Whether the outermost ground mounts the ambient layer. Flat surfaces
  /// that own the scope for nested grounds — but stay solid themselves —
  /// pass false.
  final bool ambient;
  final Widget child;

  @override
  State<LicoWindowGround> createState() => _LicoWindowGroundState();
}

final class _LicoWindowGroundState extends State<LicoWindowGround>
    implements LicoWindowGroundSite {
  final LicoAmbientInteraction _interaction = LicoAmbientInteraction();
  final LicoGlassRegionRegistry _glassRegions = LicoGlassRegionRegistry();

  @override
  RenderBox? get renderBox => context.findRenderObject() as RenderBox?;

  @override
  LicoAmbientInteraction get interaction => _interaction;

  @override
  LicoGlassRegionRegistry get glassRegions => _glassRegions;

  @override
  bool get paintsGlassSmoke =>
      LicoGalaxyProgram.isLoaded &&
      context.licoColors.ambientEffect == LicoAmbientEffect.starfield;

  @override
  bool get animatesAmbient => paintsGlassSmoke && context.allowsAmbientMotion;

  @override
  void initState() {
    super.initState();
    LicoGalaxyProgram.loaded.addListener(_onProgramLoaded);
  }

  void _onProgramLoaded() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    LicoGalaxyProgram.loaded.removeListener(_onProgramLoaded);
    _glassRegions.dispose();
    _interaction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (LicoWindowGroundScope.maybeOf(context) != null) {
      // Nested ground: a pure pass-through — the outermost (shell) ground
      // owns the window fill and the ambient layer, so a nested ground
      // mounts neither; its color is ignored.
      return widget.child;
    }
    return LicoWindowGroundScope(
      site: this,
      paintsGlassSmoke: paintsGlassSmoke,
      animatesAmbient: animatesAmbient,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: widget.color),
          if (widget.ambient) LicoAmbientLayer(site: this),
          MouseRegion(
            onHover: (event) =>
                _interaction.pointer.value = event.localPosition,
            onExit: (_) => _interaction.pointer.value = null,
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
