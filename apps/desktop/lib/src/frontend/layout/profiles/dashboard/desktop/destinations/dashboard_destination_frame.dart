import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void validateDashboardDesktopDestination(
  LayoutDestinationBuildContext data,
  ClientSection expected,
) {
  if (data.destination != expected ||
      data.environment.surface != LayoutRuntimeSurface.desktop) {
    throw const FormatException('dashboard_desktop_destination_invalid');
  }
}

/// The Dashboard destination pane: parent-owned feature content rendered
/// flush into the window body on an opaque fill — the shell keeps only the
/// folder-sidebar card translucent, so panes re-paint the window background.
final class DashboardDesktopDestinationFrame extends StatelessWidget {
  const DashboardDesktopDestinationFrame({
    super.key,
    required this.data,
    required this.title,
  });

  final LayoutDestinationBuildContext data;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: ValueKey<String>(
        'dashboard-desktop-destination-${data.destination.name}',
      ),
      container: true,
      label: title,
      explicitChildNodes: true,
      child: ColoredBox(
        color: context.licoColors.background,
        child: data.content.buildDestination(context, data.destination),
      ),
    );
  }
}
