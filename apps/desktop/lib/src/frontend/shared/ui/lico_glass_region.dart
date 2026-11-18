import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';

/// Marks [child]'s surface as glass over the ambient ground. Registers its
/// render box and [borderRadius] with the nearest owning `LicoWindowGround`
/// so the ambient effect can soften what shines through the glass; the
/// registration is removed on dispose. With no owning ground above, the
/// region is inert and renders [child] untouched.
///
/// Content inside the region reads [hostsContent]: opaque full-bleed fills
/// skip painting there so the softened ground shows through the glass, while
/// surfaces outside glass keep their fill.
final class LicoGlassRegion extends StatefulWidget {
  const LicoGlassRegion({
    super.key,
    required this.borderRadius,
    required this.child,
    this.softens = true,
  });

  final BorderRadius borderRadius;
  final Widget child;

  /// Whether this surface joins the ambient's smoke transfer. Nav glass is
  /// clear — it keeps its own faint veil and lets the ambient read through
  /// untouched — so it publishes [hostsContent] but never registers for
  /// smoke.
  final bool softens;

  /// Whether [context] sits inside a glass region: content should skip
  /// opaque full-bleed fills so the ambient ground reads through the glass.
  static bool hostsContent(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlassRegionMarker>() != null;

  @override
  State<LicoGlassRegion> createState() => _LicoGlassRegionState();
}

/// Cheap marker published by [LicoGlassRegion].
final class _GlassRegionMarker extends InheritedWidget {
  const _GlassRegionMarker({required super.child});

  @override
  bool updateShouldNotify(_GlassRegionMarker oldWidget) => false;
}

final class _LicoGlassRegionState extends State<LicoGlassRegion>
    implements LicoGlassRegionSurface {
  @override
  bool get softens => widget.softens;

  LicoGlassRegionRegistry? _registry;
  bool _active = true;

  // findRenderObject throws while the element is inactive — the brief
  // deactivate→dispose window — so the getter reports no box then; the
  // unregister on dispose removes the region a frame later.
  @override
  RenderBox? get renderBox =>
      _active ? context.findRenderObject() as RenderBox? : null;

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  BorderRadius get borderRadius => widget.borderRadius;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = LicoWindowGroundScope.maybeOf(context)?.glassRegions;
    final joined = widget.softens ? next : null;
    if (!identical(joined, _registry)) {
      _registry?.unregister(this);
      _registry = joined;
      _registry?.register(this);
    }
  }

  @override
  void dispose() {
    _registry?.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _GlassRegionMarker(child: widget.child);
}
