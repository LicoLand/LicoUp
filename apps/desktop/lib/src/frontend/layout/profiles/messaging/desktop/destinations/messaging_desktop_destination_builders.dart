import 'dart:collection';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/destinations/agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/destinations/single_pane_destinations.dart';

final Map<ClientSection, LayoutDestinationBuilder>
messagingDesktopDestinationBuilders =
    UnmodifiableMapView(<ClientSection, LayoutDestinationBuilder>{
      ClientSection.agents: buildMessagingAgentsDestination,
      ClientSection.monitoring: buildMessagingMonitoringDestination,
      ClientSection.skillHub: buildMessagingSkillHubDestination,
      ClientSection.pluginManagement: buildMessagingPluginManagementDestination,
      ClientSection.mobileRelay: buildMessagingMobileRelayDestination,
      ClientSection.models: buildMessagingModelsDestination,
      ClientSection.settings: buildMessagingSettingsDestination,
    });
