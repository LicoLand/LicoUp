import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/destinations/classic_agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/destinations/classic_feed_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/destinations/classic_pairing_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/destinations/classic_settings_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_shell.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_tokens.dart';

final LayoutSurfaceBundle classicMobileBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('classic'),
    label: LayoutProfileCopy(english: 'Dashboard', chinese: 'Dashboard'),
    description: LayoutProfileCopy(
      english:
          'Dashboard layout: left section rail, title bar, and bottom status bar control-panel arrangement.',
      chinese: 'Dashboard 布局：左侧分区导航、标题栏与底状态栏的控制台式排布。',
    ),
    styleIdentity: classicMobileStyleIdentity,
    isDefault: false,
  ),
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildClassicMobileCompactShell,
      destinationBuilders: _classicMobileDestinationBuilders(),
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildClassicMobileMediumShell,
      destinationBuilders: _classicMobileDestinationBuilders(),
    ),
  },
  previewBuilder: buildClassicMobilePreview,
  tokens: classicMobileTokens,
  components: const ClassicMobileComponentKit(),
  assetNamespace: 'layout-profiles/classic/mobile',
  restorationNamespace: classicMobileRestorationPrefix,
  stateNamespaces: {
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsDestination,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('classic'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);

Map<ClientSection, LayoutDestinationBuilder>
_classicMobileDestinationBuilders() => {
  ClientSection.agents: buildClassicAgentsDestination,
  ClientSection.feed: buildClassicFeedDestination,
  ClientSection.mobileRelay: buildClassicPairingDestination,
  ClientSection.settings: buildClassicSettingsDestination,
};
