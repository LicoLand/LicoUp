import 'dart:collection';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/control_panel_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/local_runtime_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/mcp_plugins_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/mobile_relay_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/monitoring_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/settings_destination.dart';

final Map<ClientSection, LayoutDestinationBuilder>
bubbleDesktopDestinationBuilders =
    UnmodifiableMapView(<ClientSection, LayoutDestinationBuilder>{
      ClientSection.controlPanel: buildBubbleControlPanelDestination,
      ClientSection.agents: buildBubbleAgentsDestination,
      ClientSection.monitoring: buildBubbleMonitoringDestination,
      ClientSection.mcpPlugins: buildBubbleMcpPluginsDestination,
      ClientSection.localRuntime: buildBubbleLocalRuntimeDestination,
      ClientSection.mobileRelay: buildBubbleMobileRelayDestination,
      ClientSection.settings: buildBubbleSettingsDestination,
    });
