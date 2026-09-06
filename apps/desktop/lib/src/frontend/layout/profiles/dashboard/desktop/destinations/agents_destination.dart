import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_desktop_destination_presentations.dart';

/// The Dashboard Agents destination: installs the messaging presentation
/// strategy so the shared conversation workspace renders the flat recency
/// list, the participant flow, inline process status, and the plain composer,
/// then frames it with one interior glass card on the shared chat canvas.
Widget buildDashboardAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutAgentsStrategyScope(
  strategy: const AgentsPresentationStrategy.messaging(),
  child: LayoutDestinationPresentationScope(
    agents: dashboardDesktopAgentsPresentation,
    child: DashboardDestinationFrame(
      data: data,
      expectedDestination: ClientSection.agents,
    ),
  ),
);
