import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/components/dashboard_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/agent_hub_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/skill_hub_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/mobile_relay_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/monitoring_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/models_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/plugin_management_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/preview/dashboard_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

/// The sole public artifact of the Dashboard desktop renderer.
final LayoutSurfaceBundle dashboardDesktopBundle = LayoutSurfaceBundle(
  profile: BuiltInLayoutSpec.dashboard,
  surface: LayoutRuntimeSurface.desktop,
  variants: {
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildDashboardDesktopMediumShell,
      destinationBuilders: _dashboardDesktopDestinationBuilders(),
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildDashboardDesktopExpandedShell,
      destinationBuilders: _dashboardDesktopDestinationBuilders(),
    ),
  },
  previewBuilder: buildDashboardDesktopPreview,
  tokens: dashboardDesktopTokens,
  components: const DashboardDesktopComponentKit(),
  assetNamespace: 'layout-profiles/dashboard/desktop',
  restorationNamespace: 'dashboard.desktop',
  stateNamespaces: BuiltInLayoutSpec.dashboardDesktopStateNamespaces,
);

Map<ClientSection, LayoutDestinationBuilder>
_dashboardDesktopDestinationBuilders() => {
  ClientSection.agents: dashboardDesktopAgentsDestinationBuilder,
  ClientSection.monitoring: dashboardDesktopMonitoringDestinationBuilder,
  ClientSection.skillHub: dashboardDesktopSkillHubDestinationBuilder,
  ClientSection.pluginManagement:
      dashboardDesktopPluginManagementDestinationBuilder,
  ClientSection.agentHub: dashboardDesktopAgentHubDestinationBuilder,
  ClientSection.mobileRelay: dashboardDesktopMobileRelayDestinationBuilder,
  ClientSection.models: dashboardDesktopModelsDestinationBuilder,
  ClientSection.settings: dashboardDesktopSettingsDestinationBuilder,
};
