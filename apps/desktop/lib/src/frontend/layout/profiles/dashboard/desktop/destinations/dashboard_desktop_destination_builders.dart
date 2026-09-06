import 'dart:collection';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/single_pane_destinations.dart';

final Map<ClientSection, LayoutDestinationBuilder>
dashboardDesktopDestinationBuilders =
    UnmodifiableMapView(<ClientSection, LayoutDestinationBuilder>{
      ClientSection.agents: buildDashboardAgentsDestination,
      ClientSection.monitoring: buildDashboardMonitoringDestination,
      ClientSection.skillHub: buildDashboardSkillHubDestination,
      ClientSection.pluginManagement: buildDashboardPluginManagementDestination,
      ClientSection.mobileRelay: buildDashboardMobileRelayDestination,
      ClientSection.models: buildDashboardModelsDestination,
      ClientSection.settings: buildDashboardSettingsDestination,
      ClientSection.agentHub: buildDashboardAgentHubDestination,
    });
