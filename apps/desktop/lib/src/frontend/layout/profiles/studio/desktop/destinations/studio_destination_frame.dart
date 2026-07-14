import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/components/studio_desktop_component_kit.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

enum StudioDestinationDockPlacement { top, leading, trailing }

enum StudioDestinationAccent { primary, info, success, warning }

/// Profile-local adapter frame. It decorates immutable destination content but
/// never resolves identity, reads services, or owns business state.
final class StudioDestinationFrame extends StatelessWidget {
  const StudioDestinationFrame({
    super.key,
    required this.data,
    required this.expectedDestination,
    required this.icon,
    required this.dockPlacement,
    required this.accent,
  });

  final LayoutDestinationBuildContext data;
  final ClientSection expectedDestination;
  final IconData icon;
  final StudioDestinationDockPlacement dockPlacement;
  final StudioDestinationAccent accent;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop ||
        data.destination != expectedDestination) {
      throw const FormatException('studio_desktop_destination_mismatch');
    }

    final tokens = context.layoutVisualTokens;
    final colors = context.licoColors;
    final destination = data.content.buildDestination(
      context,
      expectedDestination,
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        key: ValueKey<String>(
          'studio-desktop-destination-${expectedDestination.name}',
        ),
        color: colors.background,
        child: Padding(
          padding: EdgeInsets.all(tokens.spacingUnit),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final effectivePlacement = _effectivePlacement(constraints);
              final content = studioDesktopComponentKit.panel(
                context,
                key: ValueKey<String>(
                  'studio-desktop-${expectedDestination.name}-content-panel',
                ),
                child: ClipRect(
                  child: KeyedSubtree(
                    key: ValueKey<String>(
                      'studio-desktop-${expectedDestination.name}-content',
                    ),
                    child: destination,
                  ),
                ),
              );
              if (constraints.maxHeight < 32 || constraints.maxWidth < 34) {
                return content;
              }
              final dock = _StudioDestinationDock(
                destination: expectedDestination,
                icon: icon,
                placement: effectivePlacement,
                color: _accentColor(colors),
              );
              return switch (effectivePlacement) {
                StudioDestinationDockPlacement.top => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 32, child: dock),
                    Expanded(child: content),
                  ],
                ),
                StudioDestinationDockPlacement.leading => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 34, child: dock),
                    Expanded(child: content),
                  ],
                ),
                StudioDestinationDockPlacement.trailing => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: content),
                    SizedBox(width: 42, child: dock),
                  ],
                ),
              };
            },
          ),
        ),
      ),
    );
  }

  StudioDestinationDockPlacement _effectivePlacement(
    BoxConstraints constraints,
  ) {
    if (constraints.maxHeight < 72 || constraints.maxWidth < 180) {
      return StudioDestinationDockPlacement.top;
    }
    if (dockPlacement == StudioDestinationDockPlacement.trailing &&
        (data.environment.viewport != LayoutViewportClass.expanded ||
            constraints.maxWidth < 760)) {
      return StudioDestinationDockPlacement.leading;
    }
    return dockPlacement;
  }

  Color _accentColor(LicoThemeColors colors) => switch (accent) {
    StudioDestinationAccent.primary => colors.primary,
    StudioDestinationAccent.info => colors.info,
    StudioDestinationAccent.success => colors.success,
    StudioDestinationAccent.warning => colors.warning,
  };
}

final class _StudioDestinationDock extends StatelessWidget {
  const _StudioDestinationDock({
    required this.destination,
    required this.icon,
    required this.placement,
    required this.color,
  });

  final ClientSection destination;
  final IconData icon;
  final StudioDestinationDockPlacement placement;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final horizontal = placement == StudioDestinationDockPlacement.top;
    return ExcludeSemantics(
      child: DecoratedBox(
        key: ValueKey<String>(
          'studio-desktop-${destination.name}-${placement.name}-dock',
        ),
        decoration: BoxDecoration(
          color: colors.surfaceLow,
          border: _border(colors, horizontal),
        ),
        child: horizontal
            ? Row(
                children: [
                  _marker(),
                  const SizedBox(width: 8),
                  Expanded(child: _HorizontalTracks(color: colors.line)),
                ],
              )
            : Column(
                children: [
                  const SizedBox(height: 9),
                  _marker(),
                  const SizedBox(height: 10),
                  Expanded(child: _VerticalTracks(color: colors.line)),
                ],
              ),
      ),
    );
  }

  Border _border(LicoThemeColors colors, bool horizontal) => horizontal
      ? Border(
          left: BorderSide(color: color, width: 3),
          top: BorderSide(color: colors.line),
          right: BorderSide(color: colors.line),
        )
      : Border(
          top: BorderSide(color: colors.line),
          bottom: BorderSide(color: colors.line),
          left: placement == StudioDestinationDockPlacement.leading
              ? BorderSide(color: color, width: 3)
              : BorderSide(color: colors.line),
          right: placement == StudioDestinationDockPlacement.trailing
              ? BorderSide(color: color, width: 3)
              : BorderSide(color: colors.line),
        );

  Widget _marker() => Icon(icon, size: 17, color: color);
}

final class _HorizontalTracks extends StatelessWidget {
  const _HorizontalTracks({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(flex: 3, child: Container(height: 1, color: color)),
      const SizedBox(width: 6),
      Flexible(flex: 2, child: Container(height: 1, color: color)),
      const Spacer(flex: 5),
    ],
  );
}

final class _VerticalTracks extends StatelessWidget {
  const _VerticalTracks({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Flexible(flex: 2, child: Container(width: 1, color: color)),
      const SizedBox(height: 7),
      Flexible(flex: 3, child: Container(width: 1, color: color)),
      const Spacer(flex: 5),
    ],
  );
}
