import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_pairing_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_tokens.dart';

final LayoutSurfaceBundle dashboardMobileBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('dashboard'),
    label: LayoutProfileCopy(english: 'Dashboard', chinese: '仪表盘'),
    description: LayoutProfileCopy(
      english:
          'Dashboard layout: the cross-platform product shell with a spacious card dashboard.',
      chinese: 'Dashboard 布局：跨平台产品壳，宽松卡片式工作台。',
    ),
    styleIdentity: dashboardMobileStyleIdentity,
    isDefault: false,
  ),
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildDashboardMobileCompactShell,
      destinationBuilders: _dashboardMobileDestinationBuilders(),
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildDashboardMobileMediumShell,
      destinationBuilders: _dashboardMobileDestinationBuilders(),
    ),
  },
  previewBuilder: buildDashboardMobilePreview,
  tokens: dashboardMobileTokens,
  components: const DashboardMobileComponentKit(),
  assetNamespace: 'layout-profiles/dashboard/mobile',
  restorationNamespace: dashboardMobileRestorationPrefix,
  stateNamespaces: {
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);

Map<ClientSection, LayoutDestinationBuilder>
_dashboardMobileDestinationBuilders() => {
  ClientSection.agents: buildDashboardAgentsDestination,
  ClientSection.mobileRelay: buildDashboardPairingDestination,
  ClientSection.settings: buildDashboardSettingsDestination,
};
