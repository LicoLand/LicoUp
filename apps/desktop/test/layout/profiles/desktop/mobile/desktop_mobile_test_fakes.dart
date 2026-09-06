import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';

const List<ClientSection> desktopMobileTestDestinations = [
  ClientSection.agents,
  ClientSection.mobileRelay,
  ClientSection.settings,
];

String desktopMobileTestLabel(ClientSection destination) =>
    switch (destination) {
      ClientSection.agents => 'Agents',
      ClientSection.mobileRelay => 'Pairing',
      ClientSection.settings => 'Settings',
      _ => destination.name,
    };

final class FakeDesktopDestinationContent
    implements LayoutDestinationContentPort {
  FakeDesktopDestinationContent({this.color = const Color(0xffdfe8f7)});

  final Color color;
  final List<ClientSection> builds = [];

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    builds.add(destination);
    return ColoredBox(
      key: ValueKey<String>('fake-desktop-mobile-content-${destination.name}'),
      color: color,
      child: Center(
        child: Text(
          desktopMobileTestLabel(destination),
          key: ValueKey<String>(
            'fake-desktop-mobile-label-${destination.name}',
          ),
        ),
      ),
    );
  }
}
