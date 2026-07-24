import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';

const List<ClientSection> workbenchMobileTestDestinations = [
  ClientSection.agents,
  ClientSection.mobileRelay,
  ClientSection.settings,
];

String workbenchMobileTestLabel(ClientSection destination) =>
    switch (destination) {
      ClientSection.agents => 'Agents',
      ClientSection.mobileRelay => 'Pairing',
      ClientSection.settings => 'Settings',
      _ => destination.name,
    };

final class FakeWorkbenchDestinationContent
    implements LayoutDestinationContentPort {
  FakeWorkbenchDestinationContent({this.color = const Color(0xffdfe8f7)});

  final Color color;
  final List<ClientSection> builds = [];

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    builds.add(destination);
    return ColoredBox(
      key: ValueKey<String>(
        'fake-workbench-mobile-content-${destination.name}',
      ),
      color: color,
      child: Center(
        child: Text(
          workbenchMobileTestLabel(destination),
          key: ValueKey<String>(
            'fake-workbench-mobile-label-${destination.name}',
          ),
        ),
      ),
    );
  }
}
