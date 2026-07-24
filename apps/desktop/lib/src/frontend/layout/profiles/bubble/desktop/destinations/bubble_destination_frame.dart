import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/components/bubble_desktop_component_kit.dart';

enum BubbleDestinationDockPlacement { top, leading, trailing }

enum BubbleDestinationAccent { primary, info, success, warning }

/// Profile-local adapter frame. It decorates immutable destination content but
/// never resolves identity, reads services, or owns business state.
final class BubbleDestinationFrame extends StatelessWidget {
  const BubbleDestinationFrame({
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
  final BubbleDestinationDockPlacement dockPlacement;
  final BubbleDestinationAccent accent;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop ||
        data.destination != expectedDestination) {
      throw const FormatException('bubble_desktop_destination_mismatch');
    }

    final tokens = context.layoutVisualTokens;
    final colors = context.layoutPalette;
    final destination = data.content.buildDestination(
      context,
      expectedDestination,
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        key: ValueKey<String>(
          'bubble-desktop-destination-${expectedDestination.name}',
        ),
        color: colors.background,
        child: Padding(
          padding: EdgeInsets.all(tokens.spacingUnit),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final effectivePlacement = _effectivePlacement(constraints);
              final content = bubbleDesktopComponentKit.panel(
                context,
                key: ValueKey<String>(
                  'bubble-desktop-${expectedDestination.name}-content-panel',
                ),
                child: ClipRect(
                  child: KeyedSubtree(
                    key: ValueKey<String>(
                      'bubble-desktop-${expectedDestination.name}-content',
                    ),
                    child: destination,
                  ),
                ),
              );
              if (constraints.maxHeight < 32 || constraints.maxWidth < 34) {
                return content;
              }
              final dock = _BubbleDestinationDock(
                destination: expectedDestination,
                icon: icon,
                placement: effectivePlacement,
                color: _accentColor(colors),
              );
              return switch (effectivePlacement) {
                BubbleDestinationDockPlacement.top => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: 32, child: dock),
                    Expanded(child: content),
                  ],
                ),
                BubbleDestinationDockPlacement.leading => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 34, child: dock),
                    Expanded(child: content),
                  ],
                ),
                BubbleDestinationDockPlacement.trailing => Row(
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

  BubbleDestinationDockPlacement _effectivePlacement(
    BoxConstraints constraints,
  ) {
    if (constraints.maxHeight < 72 || constraints.maxWidth < 180) {
      return BubbleDestinationDockPlacement.top;
    }
    if (dockPlacement == BubbleDestinationDockPlacement.trailing &&
        (data.environment.viewport != LayoutViewportClass.expanded ||
            constraints.maxWidth < 760)) {
      return BubbleDestinationDockPlacement.leading;
    }
    return dockPlacement;
  }

  Color _accentColor(LayoutPalette colors) => switch (accent) {
    BubbleDestinationAccent.primary => colors.primary,
    BubbleDestinationAccent.info => colors.info,
    BubbleDestinationAccent.success => colors.success,
    BubbleDestinationAccent.warning => colors.warning,
  };
}

final class _BubbleDestinationDock extends StatelessWidget {
  const _BubbleDestinationDock({
    required this.destination,
    required this.icon,
    required this.placement,
    required this.color,
  });

  final ClientSection destination;
  final IconData icon;
  final BubbleDestinationDockPlacement placement;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final horizontal = placement == BubbleDestinationDockPlacement.top;
    return ExcludeSemantics(
      child: DecoratedBox(
        key: ValueKey<String>(
          'bubble-desktop-${destination.name}-${placement.name}-dock',
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

  Border _border(LayoutPalette colors, bool horizontal) => horizontal
      ? Border(
          left: BorderSide(color: color, width: 3),
          top: BorderSide(color: colors.line),
          right: BorderSide(color: colors.line),
        )
      : Border(
          top: BorderSide(color: colors.line),
          bottom: BorderSide(color: colors.line),
          left: placement == BubbleDestinationDockPlacement.leading
              ? BorderSide(color: color, width: 3)
              : BorderSide(color: colors.line),
          right: placement == BubbleDestinationDockPlacement.trailing
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
