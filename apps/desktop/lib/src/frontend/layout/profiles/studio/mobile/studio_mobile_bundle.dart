import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/destinations/studio_agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/destinations/studio_pairing_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/destinations/studio_settings_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_shell.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_tokens.dart';

/// The sole immutable entry point for the Studio mobile renderer.
final LayoutSurfaceBundle studioMobileBundle = LayoutSurfaceBundle(
  profile: _studioProfile,
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildStudioMobileCompactShell,
      destinationBuilders: _studioMobileDestinationBuilders,
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildStudioMobileMediumShell,
      destinationBuilders: _studioMobileDestinationBuilders,
    ),
  },
  previewBuilder: buildStudioMobilePreview,
  tokens: studioMobileVisualTokens,
  components: studioMobileComponents,
  assetNamespace: 'layout-profiles/studio/mobile',
  restorationNamespace: studioMobileRestorationPrefix,
  stateNamespaces: _studioMobileStateNamespaces,
);

final LayoutProfileDescriptor _studioProfile = LayoutProfileDescriptor(
  id: LayoutProfileId.parse('studio'),
  label: LayoutProfileCopy(english: 'Native', chinese: 'Native'),
  description: LayoutProfileCopy(
    english:
        'Native layout (default): Safari-style left navigation card framing traffic lights and page switching.',
    chinese: 'Native 布局（默认）：Safari 式左侧导航卡片，框住红绿灯与页面切换。',
  ),
  styleIdentity: studioMobileStyleIdentity,
  isDefault: true,
  revision: 1,
);

final Map<ClientSection, LayoutDestinationBuilder>
_studioMobileDestinationBuilders = {
  ClientSection.agents: buildStudioMobileAgentsDestination,
  ClientSection.mobileRelay: buildStudioMobilePairingDestination,
  ClientSection.settings: buildStudioMobileSettingsDestination,
};

final Set<LayoutStateNamespace> _studioMobileStateNamespaces = {
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('studio'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsHistory,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('studio'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsSidebar,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('studio'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsDestination,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('studio'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    channel: LayoutStateChannels.settingsScroll,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('studio'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    channel: LayoutStateChannels.settingsSection,
  ),
};
