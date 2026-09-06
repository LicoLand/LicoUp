import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_destination_content.dart';

/// Desktop destination adapter. Every Desktop destination rests on the main
/// canvas's glass wash; building one records the shared content port so the
/// shell can later host feature panels inside floating cards.
final class DesktopDestinationFrame extends StatelessWidget {
  const DesktopDestinationFrame({
    super.key,
    required this.data,
    required this.expectedDestination,
    this.pagePadding = EdgeInsets.zero,
    this.child,
  });

  final LayoutDestinationBuildContext data;
  final ClientSection expectedDestination;
  final EdgeInsetsGeometry pagePadding;

  /// Overrides the framed content (the settings copy frames its own
  /// composition instead of the raw destination panel).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop ||
        data.destination != expectedDestination) {
      throw const FormatException('desktop_desktop_destination_mismatch');
    }

    DesktopDestinationContentRegistry.contentPort = data.content;

    final destination =
        child ?? data.content.buildDestination(context, expectedDestination);
    final framed = pagePadding == EdgeInsets.zero
        ? destination
        : Padding(padding: pagePadding, child: destination);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: KeyedSubtree(
        key: ValueKey<String>(
          'desktop-desktop-destination-${expectedDestination.name}',
        ),
        child: KeyedSubtree(
          key: ValueKey<String>(
            'desktop-desktop-${expectedDestination.name}-content',
          ),
          child: framed,
        ),
      ),
    );
  }
}
