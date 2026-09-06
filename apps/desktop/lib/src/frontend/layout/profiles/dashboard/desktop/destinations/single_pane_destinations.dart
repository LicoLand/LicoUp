import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

Widget buildDashboardMonitoringDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(
  data,
  ClientSection.monitoring,
  // Full-width destination: clear the shell traffic-light row that overlays
  // the main card top-left.
  pagePadding: const EdgeInsets.only(
    top: MessagingDesktopMetrics.trafficLightRowClearance,
  ),
);

Widget buildDashboardSkillHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.skillHub);

Widget buildDashboardPluginManagementDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.pluginManagement);

Widget buildDashboardMobileRelayDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.mobileRelay);

Widget buildDashboardModelsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.models);

Widget buildDashboardSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  settings: dashboardDesktopSettingsPresentation,
  child: _framed(
    data,
    ClientSection.settings,
    pagePadding: MessagingDesktopMetrics.mainPanePadding,
  ),
);

Widget buildDashboardAgentHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.agentHub);

Widget _framed(
  LayoutDestinationBuildContext data,
  ClientSection destination, {
  EdgeInsetsGeometry pagePadding = EdgeInsets.zero,
}) => DashboardDestinationFrame(
  data: data,
  expectedDestination: destination,
  pagePadding: pagePadding,
);
