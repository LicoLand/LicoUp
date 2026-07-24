import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/components/classic_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/skill_hub_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/mobile_relay_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/monitoring_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/plugin_management_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/preview/classic_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/shell/classic_desktop_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/tokens/classic_desktop_tokens.dart';

/// The sole public artifact of the classic desktop renderer.
final LayoutSurfaceBundle classicDesktopBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('classic'),
    label: LayoutProfileCopy(english: 'Dashboard', chinese: 'Dashboard'),
    description: LayoutProfileCopy(
      english:
          'Dashboard layout: left section rail, title bar, and bottom status bar control-panel arrangement.',
      chinese: 'Dashboard 布局：左侧分区导航、标题栏与底状态栏的控制台式排布。',
    ),
    styleIdentity: 'spacious-card-classic',
    isDefault: false,
  ),
  surface: LayoutRuntimeSurface.desktop,
  variants: {
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildClassicDesktopMediumShell,
      destinationBuilders: _classicDesktopDestinationBuilders(),
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildClassicDesktopExpandedShell,
      destinationBuilders: _classicDesktopDestinationBuilders(),
    ),
  },
  previewBuilder: buildClassicDesktopPreview,
  tokens: classicDesktopTokens,
  components: const ClassicDesktopComponentKit(),
  assetNamespace: 'layout-profiles/classic/desktop',
  restorationNamespace: 'classic.desktop',
  stateNamespaces: {
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);

Map<ClientSection, LayoutDestinationBuilder>
_classicDesktopDestinationBuilders() => {
  ClientSection.agents: classicDesktopAgentsDestinationBuilder,
  ClientSection.monitoring: classicDesktopMonitoringDestinationBuilder,
  ClientSection.skillHub: classicDesktopSkillHubDestinationBuilder,
  ClientSection.pluginManagement:
      classicDesktopPluginManagementDestinationBuilder,
  ClientSection.mobileRelay: classicDesktopMobileRelayDestinationBuilder,
  ClientSection.settings: classicDesktopSettingsDestinationBuilder,
};
