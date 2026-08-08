import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';

/// Messaging destination adapter. Every messaging desktop destination rests
/// flush on the shell main content card's glass wash (transparent canvas).
final class MessagingDestinationFrame extends StatelessWidget {
  const MessagingDestinationFrame({
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
      throw const FormatException('messaging_desktop_destination_mismatch');
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
          'messaging-desktop-destination-${expectedDestination.name}',
        ),
        child: KeyedSubtree(
          key: ValueKey<String>(
            'messaging-desktop-${expectedDestination.name}-content',
          ),
          child: destination,
        ),
      ),
    );
  }
}
