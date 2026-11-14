import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';

/// Dashboard destination adapter. Every Dashboard desktop destination rests
/// on the shell main content card's glass wash (transparent canvas).
final class DashboardDestinationFrame extends StatelessWidget {
  const DashboardDestinationFrame({
    super.key,
    required this.data,
    required this.expectedDestination,
    this.pagePadding = EdgeInsets.zero,
    this.arrange,
  });

  final LayoutDestinationBuildContext data;
  final ClientSection expectedDestination;

  /// Inner page inset shared by single-pane destinations. Agents keeps
  /// [EdgeInsets.zero] so the conversation split stays flush to the card.
  final EdgeInsetsGeometry pagePadding;

  /// Places style-owned chrome around the destination content.
  final Widget Function(BuildContext context, Widget content)? arrange;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop ||
        data.destination != expectedDestination) {
      throw const FormatException('dashboard_desktop_destination_mismatch');
    }

    final destination = data.content.buildDestination(
      context,
      expectedDestination,
    );
    final arranged = arrange?.call(context, destination) ?? destination;
    final child = pagePadding == EdgeInsets.zero
        ? arranged
        : Padding(padding: pagePadding, child: arranged);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: KeyedSubtree(
        key: ValueKey<String>(
          'dashboard-desktop-destination-${expectedDestination.name}',
        ),
        child: KeyedSubtree(
          key: ValueKey<String>(
            'dashboard-desktop-${expectedDestination.name}-content',
          ),
          child: child,
        ),
      ),
    );
  }
}
