import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_card_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_plain_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

/// The Dashboard Settings destination. The two-column style keeps the shared
/// sidebar's section index and the pane inset; the three-column (plain)
/// style hosts the section index in the shell's list column instead, and
/// the detail is the settings content alone on the flat surface. Both
/// sides follow the shared section channel, so selecting a section scrolls
/// the content and scrolling the content moves the selection.
Widget buildDashboardSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  final plain = dashboardPlainStyleActive(data.style);
  return LayoutDestinationPresentationScope(
    settings: plain
        ? dashboardPlainSettingsPresentation
        : dashboardCardSettingsPresentation,
    child: DashboardDestinationFrame(
      data: data,
      expectedDestination: ClientSection.settings,
      pagePadding: plain
          ? DashboardPlainMetrics.mainViewPadding
          : MessagingDesktopMetrics.mainPanePadding,
    ),
  );
}
