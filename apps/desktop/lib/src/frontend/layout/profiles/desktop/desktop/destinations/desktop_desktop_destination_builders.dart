import 'dart:collection';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/destinations/desktop_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/presentation/desktop_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/settings/desktop_settings_app.dart';

/// Desktop destination builders. 对话 and 设置 are fullscreen-exclusive apps:
/// 对话 installs the messaging presentation strategy (participant flow, plain
/// composer) so the shared conversation workspace renders the same chat
/// surface it does elsewhere, and 设置 mounts the desktop-owned settings copy.
/// Every other destination frames the shared feature panel unchanged.
final Map<ClientSection, LayoutDestinationBuilder>
desktopDesktopDestinationBuilders =
    UnmodifiableMapView(<ClientSection, LayoutDestinationBuilder>{
      ClientSection.agents: buildDesktopAgentsDestination,
      ClientSection.monitoring: buildDesktopMonitoringDestination,
      ClientSection.skillHub: buildDesktopSkillHubDestination,
      ClientSection.pluginManagement: buildDesktopPluginManagementDestination,
      ClientSection.mobileRelay: buildDesktopMobileRelayDestination,
      ClientSection.models: buildDesktopModelsDestination,
      ClientSection.settings: buildDesktopSettingsDestination,
      ClientSection.agentHub: buildDesktopAgentHubDestination,
    });

Widget buildDesktopAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutAgentsStrategyScope(
  strategy: const AgentsPresentationStrategy.messaging(),
  child: LayoutDestinationPresentationScope(
    agents: desktopDesktopAgentsPresentation,
    child: DesktopDestinationFrame(
      data: data,
      expectedDestination: ClientSection.agents,
    ),
  ),
);

Widget buildDesktopSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  settings: desktopDesktopSettingsPresentation,
  child: DesktopDestinationFrame(
    data: data,
    expectedDestination: ClientSection.settings,
    child: DesktopSettingsApp(data: data),
  ),
);

Widget buildDesktopMonitoringDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.monitoring);

Widget buildDesktopSkillHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.skillHub);

Widget buildDesktopPluginManagementDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.pluginManagement);

Widget buildDesktopMobileRelayDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.mobileRelay);

Widget buildDesktopModelsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.models);

Widget buildDesktopAgentHubDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => _framed(data, ClientSection.agentHub);

Widget _framed(LayoutDestinationBuildContext data, ClientSection destination) =>
    DesktopDestinationFrame(data: data, expectedDestination: destination);
