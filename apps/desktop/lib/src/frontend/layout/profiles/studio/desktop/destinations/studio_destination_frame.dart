import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';

/// Native destination adapter: flush content on the shared canvas.
///
/// No decorative leading/trailing dock — navigation already lives in the
/// floating Safari sidebar card.
final class StudioDestinationFrame extends StatelessWidget {
  const StudioDestinationFrame({
    super.key,
    required this.data,
    required this.expectedDestination,
  });

  final LayoutDestinationBuildContext data;
  final ClientSection expectedDestination;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop ||
        data.destination != expectedDestination) {
      throw const FormatException('studio_desktop_destination_mismatch');
    }

    final destination = data.content.buildDestination(
      context,
      expectedDestination,
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: KeyedSubtree(
        key: ValueKey<String>(
          'studio-desktop-destination-${expectedDestination.name}',
        ),
        child: KeyedSubtree(
          key: ValueKey<String>(
            'studio-desktop-${expectedDestination.name}-content',
          ),
          child: destination,
        ),
      ),
    );
  }
}
