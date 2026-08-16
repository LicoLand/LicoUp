import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/components/messaging_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/destinations/messaging_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/preview/messaging_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_desktop_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// The sole public handoff from the Default desktop renderer boundary.
final LayoutSurfaceBundle messagingDesktopBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('messaging'),
    label: LayoutProfileCopy(english: 'Default', chinese: '默认'),
    description: LayoutProfileCopy(
      english:
          'Default layout: a flat conversation list, participant-style chat flow, and agent runtime details tucked into a details panel.',
      chinese: '默认布局：扁平会话列表、参与者式聊天流，智能体运行细节收进详情面板。',
    ),
    styleIdentity: 'messaging-channel-chat',
    isDefault: true,
    revision: 1,
  ),
  surface: LayoutRuntimeSurface.desktop,
  variants: <LayoutViewportClass, LayoutSurfaceVariant>{
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildMessagingDesktopMediumShell,
      destinationBuilders: messagingDesktopDestinationBuilders,
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildMessagingDesktopExpandedShell,
      destinationBuilders: messagingDesktopDestinationBuilders,
    ),
  },
  previewBuilder: buildMessagingDesktopPreview,
  tokens: messagingDesktopTokens,
  components: messagingDesktopComponentKit,
  assetNamespace: 'layout-profiles/messaging/desktop',
  restorationNamespace: 'messaging.desktop',
  stateNamespaces: <LayoutStateNamespace>{
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('messaging'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('messaging'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('messaging'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('messaging'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('messaging'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsIndex,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('messaging'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.models,
      channel: LayoutStateChannels.communicationSection,
    ),
  },
);
