import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/destinations/messaging_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/presentation/messaging_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

Widget buildMessagingMonitoringDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.monitoring);

Widget buildMessagingSkillHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.skillHub);

Widget buildMessagingPluginManagementDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.pluginManagement);

Widget buildMessagingMobileRelayDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.mobileRelay);

Widget buildMessagingModelsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.models);

Widget buildMessagingSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  settings: messagingDesktopSettingsPresentation,
  child: _framed(
    data,
    ClientSection.settings,
    pagePadding: MessagingDesktopMetrics.mainPanePadding,
  ),
);

Widget buildMessagingAgentHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.agentHub);

Widget _framed(
  LayoutDestinationBuildContext data,
  ClientSection destination, {
  EdgeInsetsGeometry pagePadding = EdgeInsets.zero,
}) => MessagingDestinationFrame(
  data: data,
  expectedDestination: destination,
  pagePadding: pagePadding,
);
