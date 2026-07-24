import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/destinations/bubble_agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/destinations/bubble_pairing_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/destinations/bubble_settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_tokens.dart';

/// The sole immutable entry point for the Bubble mobile renderer.
final LayoutSurfaceBundle bubbleMobileBundle = LayoutSurfaceBundle(
  profile: _bubbleProfile,
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildBubbleMobileCompactShell,
      destinationBuilders: _bubbleMobileDestinationBuilders,
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildBubbleMobileMediumShell,
      destinationBuilders: _bubbleMobileDestinationBuilders,
    ),
  },
  previewBuilder: buildBubbleMobilePreview,
  tokens: bubbleMobileVisualTokens,
  components: bubbleMobileComponents,
  assetNamespace: 'layout-profiles/bubble/mobile',
  restorationNamespace: bubbleMobileRestorationPrefix,
  stateNamespaces: _bubbleMobileStateNamespaces,
);

final LayoutProfileDescriptor _bubbleProfile = LayoutProfileDescriptor(
  id: LayoutProfileId.parse('bubble'),
  label: LayoutProfileCopy(english: 'Bubble', chinese: 'Bubble'),
  description: LayoutProfileCopy(
    english:
        'Bubble layout: floating capsule rail navigation with inverted Agents chrome.',
    chinese: 'Bubble 布局：左侧浮动胶囊轨道导航与智能体反转卡片。',
  ),
  styleIdentity: bubbleMobileStyleIdentity,
  isDefault: false,
  revision: 1,
);

final Map<ClientSection, LayoutDestinationBuilder>
_bubbleMobileDestinationBuilders = {
  ClientSection.agents: buildBubbleMobileAgentsDestination,
  ClientSection.mobileRelay: buildBubbleMobilePairingDestination,
  ClientSection.settings: buildBubbleMobileSettingsDestination,
};

final Set<LayoutStateNamespace> _bubbleMobileStateNamespaces = {
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('bubble'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsHistory,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('bubble'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsSidebar,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('bubble'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    channel: LayoutStateChannels.settingsScroll,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('bubble'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    channel: LayoutStateChannels.settingsSection,
  ),
};
