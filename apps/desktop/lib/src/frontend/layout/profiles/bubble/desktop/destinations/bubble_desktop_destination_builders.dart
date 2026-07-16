import 'dart:collection';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/skill_hub_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/mobile_relay_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/monitoring_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/settings_destination.dart';

final Map<ClientSection, LayoutDestinationBuilder>
bubbleDesktopDestinationBuilders =
    UnmodifiableMapView(<ClientSection, LayoutDestinationBuilder>{
      ClientSection.agents: buildBubbleAgentsDestination,
      ClientSection.monitoring: buildBubbleMonitoringDestination,
      ClientSection.skillHub: buildBubbleSkillHubDestination,
      ClientSection.mobileRelay: buildBubbleMobileRelayDestination,
      ClientSection.settings: buildBubbleSettingsDestination,
    });
