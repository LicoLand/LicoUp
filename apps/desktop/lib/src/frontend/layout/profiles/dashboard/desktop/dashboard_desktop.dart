import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/components/dashboard_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/agents_destination.dart';
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
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('dashboard'),
    label: LayoutProfileCopy(english: 'Dashboard', chinese: '仪表盘'),
    description: LayoutProfileCopy(
      english:
          'Dashboard layout: the cross-platform product shell with a spacious card dashboard.',
      chinese: 'Dashboard 布局：跨平台产品壳，宽松卡片式工作台。',
    ),
    styleIdentity: 'spacious-card-dashboard',
    isDefault: false,
  ),
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
  stateNamespaces: {
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);

Map<ClientSection, LayoutDestinationBuilder>
_dashboardDesktopDestinationBuilders() => {
  ClientSection.agents: dashboardDesktopAgentsDestinationBuilder,
  ClientSection.monitoring: dashboardDesktopMonitoringDestinationBuilder,
  ClientSection.skillHub: dashboardDesktopSkillHubDestinationBuilder,
  ClientSection.pluginManagement:
      dashboardDesktopPluginManagementDestinationBuilder,
  ClientSection.mobileRelay: dashboardDesktopMobileRelayDestinationBuilder,
  ClientSection.models: dashboardDesktopModelsDestinationBuilder,
  ClientSection.settings: dashboardDesktopSettingsDestinationBuilder,
};
