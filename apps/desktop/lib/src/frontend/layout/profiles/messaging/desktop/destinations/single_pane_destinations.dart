import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/destinations/messaging_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/presentation/messaging_desktop_destination_presentations.dart';

Widget buildMessagingMonitoringDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => MessagingDestinationFrame(
  data: data,
  expectedDestination: ClientSection.monitoring,
);

Widget buildMessagingSkillHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => MessagingDestinationFrame(
  data: data,
  expectedDestination: ClientSection.skillHub,
);

Widget buildMessagingPluginManagementDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => MessagingDestinationFrame(
  data: data,
  expectedDestination: ClientSection.pluginManagement,
);

Widget buildMessagingMobileRelayDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => MessagingDestinationFrame(
  data: data,
  expectedDestination: ClientSection.mobileRelay,
);

Widget buildMessagingModelsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => MessagingDestinationFrame(
  data: data,
  expectedDestination: ClientSection.models,
);

Widget buildMessagingSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  settings: messagingDesktopSettingsPresentation,
  child: MessagingDestinationFrame(
    data: data,
    expectedDestination: ClientSection.settings,
  ),
);
