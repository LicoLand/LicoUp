import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/destinations/native_agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/destinations/native_pairing_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/destinations/native_settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/native_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/native_mobile_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/native_mobile_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/native_mobile_tokens.dart';

/// The sole immutable entry point for the Native mobile renderer.
final LayoutSurfaceBundle nativeMobileBundle = LayoutSurfaceBundle(
  profile: _nativeProfile,
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildNativeMobileCompactShell,
      destinationBuilders: _nativeMobileDestinationBuilders,
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildNativeMobileMediumShell,
      destinationBuilders: _nativeMobileDestinationBuilders,
    ),
  },
  previewBuilder: buildNativeMobilePreview,
  tokens: nativeMobileVisualTokens,
  components: nativeMobileComponents,
  assetNamespace: 'layout-profiles/native/mobile',
  restorationNamespace: nativeMobileRestorationPrefix,
  stateNamespaces: _nativeMobileStateNamespaces,
);

final LayoutProfileDescriptor _nativeProfile = LayoutProfileDescriptor(
  id: LayoutProfileId.parse('native'),
  label: LayoutProfileCopy(english: 'Native', chinese: 'Native'),
  description: LayoutProfileCopy(
    english:
        'Native layout (default): an icon rail and top band on the window background, a flush conversation list one step above, and the destination detail as the lightest top layer.',
    chinese: 'Native 布局（默认）：图标导航轨与顶栏落在窗口背景上，对话列表平铺为第二层，内容详情是最浅的第三层。',
  ),
  styleIdentity: nativeMobileStyleIdentity,
  isDefault: true,
  revision: 3,
);

final Map<ClientSection, LayoutDestinationBuilder>
_nativeMobileDestinationBuilders = {
  ClientSection.agents: buildNativeMobileAgentsDestination,
  ClientSection.mobileRelay: buildNativeMobilePairingDestination,
  ClientSection.settings: buildNativeMobileSettingsDestination,
};

final Set<LayoutStateNamespace> _nativeMobileStateNamespaces = {
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('native'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsHistory,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('native'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: LayoutStateChannels.agentsSidebar,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('native'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    channel: LayoutStateChannels.settingsScroll,
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('native'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.settings,
    channel: LayoutStateChannels.settingsSection,
  ),
};
