import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/destinations/studio_agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/destinations/studio_feed_destination.dart';
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
  id: LayoutProfileId.studio,
  labelKey: 'layout.profile.studio.label',
  descriptionKey: 'layout.profile.studio.description',
  styleIdentity: studioMobileStyleIdentity,
  isDefault: false,
  revision: 1,
);

final Map<ClientSection, LayoutDestinationBuilder>
_studioMobileDestinationBuilders = {
  ClientSection.agents: buildStudioMobileAgentsDestination,
  ClientSection.feed: buildStudioMobileFeedDestination,
  ClientSection.mobileRelay: buildStudioMobilePairingDestination,
  ClientSection.settings: buildStudioMobileSettingsDestination,
};

final Set<LayoutStateNamespace> _studioMobileStateNamespaces = {
  LayoutStateNamespace(
    profileId: LayoutProfileId.studio,
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    surfaceId: 'conversation-scroll',
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.studio,
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.feed,
    surfaceId: 'feed-scroll',
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.studio,
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.mobileRelay,
    surfaceId: 'pairing-flow',
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.studio,
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    surfaceId: 'settings-scroll',
  ),
};
