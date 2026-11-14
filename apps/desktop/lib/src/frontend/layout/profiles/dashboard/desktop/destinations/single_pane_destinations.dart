import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_destination_frame.dart';

Widget buildDashboardMonitoringDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(context, data, ClientSection.monitoring);

Widget buildDashboardSkillHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(context, data, ClientSection.skillHub);

Widget buildDashboardPluginManagementDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(context, data, ClientSection.pluginManagement);

Widget buildDashboardDevicesDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(context, data, ClientSection.devices);

Widget buildDashboardModelsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(context, data, ClientSection.models);

/// Agent Hub replaces the list column and the chat pane in the plain
/// style; its own pane scaffold supplies the title and the content inset.
Widget buildDashboardAgentHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(context, data, ClientSection.agentHub);

/// The shell's window ground owns the window fill and the ambient layer;
/// destinations mount only their presentation frame so the clear pane
/// stays readable through them.
Widget _framed(
  BuildContext context,
  LayoutDestinationBuildContext data,
  ClientSection destination, {
  EdgeInsetsGeometry pagePadding = EdgeInsets.zero,
}) {
  return DashboardDestinationFrame(
    data: data,
    expectedDestination: destination,
    pagePadding: pagePadding,
  );
}
