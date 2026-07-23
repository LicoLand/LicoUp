import 'dart:collection';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/skill_hub_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/mobile_relay_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/monitoring_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/settings_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/plugin_management_destination.dart';

final Map<ClientSection, LayoutDestinationBuilder>
nativeDesktopDestinationBuilders =
    UnmodifiableMapView(<ClientSection, LayoutDestinationBuilder>{
      ClientSection.agents: buildNativeAgentsDestination,
      ClientSection.monitoring: buildNativeMonitoringDestination,
      ClientSection.skillHub: buildNativeSkillHubDestination,
      ClientSection.pluginManagement: buildNativePluginManagementDestination,
      ClientSection.mobileRelay: buildNativeMobileRelayDestination,
      ClientSection.settings: buildNativeSettingsDestination,
    });
