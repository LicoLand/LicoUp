import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/destinations/messaging_agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/destinations/messaging_pairing_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/destinations/messaging_settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_tokens.dart';

/// The sole immutable entry point for the Messaging mobile renderer.
final LayoutSurfaceBundle messagingMobileBundle = LayoutSurfaceBundle(
  profile: _messagingProfile,
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildMessagingMobileCompactShell,
      destinationBuilders: _messagingMobileDestinationBuilders,
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildMessagingMobileMediumShell,
      destinationBuilders: _messagingMobileDestinationBuilders,
    ),
  },
  previewBuilder: buildMessagingMobilePreview,
  tokens: messagingMobileVisualTokens,
  components: messagingMobileComponents,
  assetNamespace: 'layout-profiles/messaging/mobile',
  restorationNamespace: messagingMobileRestorationPrefix,
  stateNamespaces: _messagingMobileStateNamespaces,
);

final LayoutProfileDescriptor _messagingProfile = LayoutProfileDescriptor(
  id: LayoutProfileId.parse('messaging'),
  label: LayoutProfileCopy(english: 'Default', chinese: '默认'),
  description: LayoutProfileCopy(
    english:
        'Default layout: a flat conversation list, participant-style chat flow, and agent runtime details tucked into a details panel.',
    chinese: '默认布局：扁平会话列表、参与者式聊天流，智能体运行细节收进详情面板。',
  ),
  styleIdentity: messagingMobileStyleIdentity,
  isDefault: true,
  revision: 1,
);

final Map<ClientSection, LayoutDestinationBuilder>
_messagingMobileDestinationBuilders = {
  ClientSection.agents: buildMessagingMobileAgentsDestination,
  ClientSection.mobileRelay: buildMessagingMobilePairingDestination,
  ClientSection.settings: buildMessagingMobileSettingsDestination,
};

final Set<LayoutStateNamespace> _messagingMobileStateNamespaces = {
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('messaging'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsHistory,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('messaging'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsSidebar,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('messaging'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    channel: LayoutStateChannels.settingsScroll,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('messaging'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    channel: LayoutStateChannels.settingsSection,
  ),
};
