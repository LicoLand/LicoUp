import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/components/workbench_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/skill_hub_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/mobile_relay_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/monitoring_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/plugin_management_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/preview/workbench_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/shell/workbench_desktop_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/tokens/workbench_desktop_tokens.dart';

/// The sole public artifact of the workbench desktop renderer.
final LayoutSurfaceBundle workbenchDesktopBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('workbench'),
    label: LayoutProfileCopy(english: 'LicoUp', chinese: 'LicoUp'),
    description: LayoutProfileCopy(
      english:
          'LicoUp standard layout (fallback): the cross-platform product shell used when Native is not the platform default.',
      chinese: 'LicoUp 标准布局（缺省）：跨平台产品壳，在无原生系统风格时作为 Native 的回退。',
    ),
    styleIdentity: 'spacious-card-workbench',
    isDefault: false,
  ),
  surface: LayoutRuntimeSurface.desktop,
  variants: {
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildWorkbenchDesktopMediumShell,
      destinationBuilders: _workbenchDesktopDestinationBuilders(),
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildWorkbenchDesktopExpandedShell,
      destinationBuilders: _workbenchDesktopDestinationBuilders(),
    ),
  },
  previewBuilder: buildWorkbenchDesktopPreview,
  tokens: workbenchDesktopTokens,
  components: const WorkbenchDesktopComponentKit(),
  assetNamespace: 'layout-profiles/workbench/desktop',
  restorationNamespace: 'workbench.desktop',
  stateNamespaces: {
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);

Map<ClientSection, LayoutDestinationBuilder>
_workbenchDesktopDestinationBuilders() => {
  ClientSection.agents: workbenchDesktopAgentsDestinationBuilder,
  ClientSection.monitoring: workbenchDesktopMonitoringDestinationBuilder,
  ClientSection.skillHub: workbenchDesktopSkillHubDestinationBuilder,
  ClientSection.pluginManagement:
      workbenchDesktopPluginManagementDestinationBuilder,
  ClientSection.mobileRelay: workbenchDesktopMobileRelayDestinationBuilder,
  ClientSection.settings: workbenchDesktopSettingsDestinationBuilder,
};
