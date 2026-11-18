import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_card_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_plain_destination_presentations.dart';

/// Whether the effective Dashboard column arrangement is the plain
/// style (the rail, list column and main view on the window ground).
bool dashboardPlainStyleActive(LayoutStyleId? style) =>
    style == BuiltInLayoutSpec.dashboardPlainStyleId;

/// The Dashboard Agents destination: installs the messaging presentation
/// strategy so the shared conversation workspace renders the flat recency
/// list, the participant flow, inline process status, and the plain composer.
/// The card style frames it with one interior glass card on the shared
/// chat canvas; the plain style rests the titled conversation list and
/// the chat pane on the window ground beside the rail.
Widget buildDashboardAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutAgentsStrategyScope(
  strategy: const AgentsPresentationStrategy.messaging(),
  child: LayoutDestinationPresentationScope(
    agents: dashboardPlainStyleActive(data.style)
        ? dashboardPlainAgentsPresentation
        : dashboardCardAgentsPresentation,
    child: DashboardDestinationFrame(
      data: data,
      expectedDestination: ClientSection.agents,
    ),
  ),
);
