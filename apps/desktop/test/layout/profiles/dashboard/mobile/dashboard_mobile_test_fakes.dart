import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';

const List<ClientSection> dashboardMobileTestDestinations = [
  ClientSection.agents,
  ClientSection.mobileRelay,
  ClientSection.settings,
];

String dashboardMobileTestLabel(ClientSection destination) =>
    switch (destination) {
      ClientSection.agents => 'Agents',
      ClientSection.mobileRelay => 'Pairing',
      ClientSection.settings => 'Settings',
      _ => destination.name,
    };

final class FakeDashboardDestinationContent
    implements LayoutDestinationContentPort {
  FakeDashboardDestinationContent({this.color = const Color(0xffdfe8f7)});

  final Color color;
  final List<ClientSection> builds = [];

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    builds.add(destination);
    return ColoredBox(
      key: ValueKey<String>(
        'fake-dashboard-mobile-content-${destination.name}',
      ),
      color: color,
      child: Center(
        child: Text(
          dashboardMobileTestLabel(destination),
          key: ValueKey<String>(
            'fake-dashboard-mobile-label-${destination.name}',
          ),
        ),
      ),
    );
  }
}
