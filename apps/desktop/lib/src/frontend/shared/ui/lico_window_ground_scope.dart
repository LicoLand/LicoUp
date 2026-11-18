import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/shared/ui/lico_ambient_interaction.dart';

/// One glass region registered with an ambient-owning ground. Implemented by
/// `LicoGlassRegion`; the ambient painter resolves [renderBox]'s rect relative
/// to the ground's render box at paint time.
abstract interface class LicoGlassRegionSurface {
  RenderBox? get renderBox;
  BorderRadius get borderRadius;

  /// Whether the ambient paints its smoke transfer inside this surface.
  bool get softens;
}

/// Live registry of the glass regions under one ground. Ambient painters
/// merge it into their repaint listenable so a region mounting or leaving
/// repaints once; position changes are resolved per paint.
final class LicoGlassRegionRegistry extends ChangeNotifier {
  final List<LicoGlassRegionSurface> _regions = <LicoGlassRegionSurface>[];

  /// Read-only view; painters iterate it per frame without allocating.
  Iterable<LicoGlassRegionSurface> get regions => _regions;

  void register(LicoGlassRegionSurface region) {
    _regions.add(region);
    notifyListeners();
  }

  void unregister(LicoGlassRegionSurface region) {
    if (_regions.remove(region)) {
      notifyListeners();
    }
  }
}

/// The ambient-ownership site a [LicoWindowGround] publishes below itself:
/// the ground's render box, its shared pointer input, and the registry of
/// glass surfaces that sit above the ambient effect.
abstract interface class LicoWindowGroundSite {
  /// The ground's render box, for resolving region rects in ground
  /// coordinates. Read-only, and only meaningful while laid out.
  RenderBox? get renderBox;

  /// The ground's shared ambient input.
  LicoAmbientInteraction get interaction;

  /// The glass surfaces registered below this ground.
  LicoGlassRegionRegistry get glassRegions;

  /// Whether the ambient shader paints the smoke-glass transfer itself:
  /// pane cards then drop their own smoke fill and shadow so the glass is
  /// not dimmed twice.
  bool get paintsGlassSmoke;

  /// Whether the ambient layer is animated (shader loaded and ambient
  /// motion allowed): live `BackdropFilter`s over it are skipped because a
  /// moving backdrop smears every frame.
  bool get animatesAmbient;
}

/// Inherited scope marking the ambient-owning ground for its subtree. A
/// nested `LicoWindowGround` sees the ancestor scope and skips mounting its
/// own ambient layer; `LicoGlassRegion` registers through it.
final class LicoWindowGroundScope extends InheritedWidget {
  const LicoWindowGroundScope({
    super.key,
    required this.site,
    required this.paintsGlassSmoke,
    required this.animatesAmbient,
    required super.child,
  });

  final LicoWindowGroundSite site;

  /// Whether the ambient shader paints the smoke transfer; pane surfaces
  /// depend on this so they restyle when the program finishes loading.
  final bool paintsGlassSmoke;

  /// Whether the ambient layer animates; glass surfaces depend on this to
  /// drop live backdrop filters (spec §9: no live blur over animated
  /// content).
  final bool animatesAmbient;

  static LicoWindowGroundSite? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LicoWindowGroundScope>()?.site;

  /// True when the owning ground's ambient shader paints the glass smoke.
  static bool paintsGlassSmokeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LicoWindowGroundScope>()
          ?.paintsGlassSmoke ??
      false;

  /// True when the owning ground's ambient layer animates.
  static bool animatesAmbientOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LicoWindowGroundScope>()
          ?.animatesAmbient ??
      false;

  @override
  bool updateShouldNotify(LicoWindowGroundScope oldWidget) =>
      !identical(oldWidget.site, site) ||
      oldWidget.paintsGlassSmoke != paintsGlassSmoke ||
      oldWidget.animatesAmbient != animatesAmbient;
}
