import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';

/// The Desktop settings surface: the shared settings panel rendered directly
/// as left-pane content. The Desktop layout carries no settings sidebar of
/// its own — the panel hosts its section index (see
/// `DesktopDesktopSettingsPresentation.indexHostedByNavigation`) — and the
/// shell's chrome row owns the traffic-light anchor, so this surface mounts
/// no anchor either.
final class DesktopSettingsApp extends StatelessWidget {
  const DesktopSettingsApp({super.key, required this.data});

  final LayoutDestinationBuildContext data;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('desktop-settings-app'),
      child: Material(
        type: MaterialType.transparency,
        child: KeyedSubtree(
          key: const Key('desktop-settings-main'),
          child: data.content.buildDestination(context, ClientSection.settings),
        ),
      ),
    );
  }
}
