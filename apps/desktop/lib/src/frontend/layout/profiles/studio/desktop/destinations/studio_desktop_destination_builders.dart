import 'dart:collection';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/control_panel_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/local_runtime_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/mcp_plugins_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/mobile_relay_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/monitoring_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/settings_destination.dart';

final Map<ClientSection, LayoutDestinationBuilder>
studioDesktopDestinationBuilders =
    UnmodifiableMapView(<ClientSection, LayoutDestinationBuilder>{
      ClientSection.controlPanel: buildStudioControlPanelDestination,
      ClientSection.agents: buildStudioAgentsDestination,
      ClientSection.monitoring: buildStudioMonitoringDestination,
      ClientSection.mcpPlugins: buildStudioMcpPluginsDestination,
      ClientSection.localRuntime: buildStudioLocalRuntimeDestination,
      ClientSection.mobileRelay: buildStudioMobileRelayDestination,
      ClientSection.settings: buildStudioSettingsDestination,
    });
