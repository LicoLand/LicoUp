import 'dart:collection';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/skill_hub_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/mobile_relay_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/monitoring_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/settings_destination.dart';

final Map<ClientSection, LayoutDestinationBuilder>
studioDesktopDestinationBuilders =
    UnmodifiableMapView(<ClientSection, LayoutDestinationBuilder>{
      ClientSection.agents: buildStudioAgentsDestination,
      ClientSection.monitoring: buildStudioMonitoringDestination,
      ClientSection.skillHub: buildStudioSkillHubDestination,
      ClientSection.mobileRelay: buildStudioMobileRelayDestination,
      ClientSection.settings: buildStudioSettingsDestination,
    });
