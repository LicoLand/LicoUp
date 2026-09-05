import 'layout_environment.dart';
import 'layout_profile.dart';
import 'layout_state_namespace.dart';
import 'layout_variant.dart';
import 'semantic_destination.dart';

/// Renderer-neutral facts for the two built-in layout products.
///
/// Application state and Flutter registries consume this same catalog so
/// neither layer duplicates profile identity, coverage, or state channels.
abstract final class BuiltInLayoutSpec {
  static final LayoutProfileDescriptor messaging = LayoutProfileDescriptor(
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
  );

  static final LayoutProfileDescriptor dashboard = LayoutProfileDescriptor(
    id: LayoutProfileId.parse('dashboard'),
    label: LayoutProfileCopy(english: 'Dashboard', chinese: '仪表盘'),
    description: LayoutProfileCopy(
      english:
          'Dashboard layout: the cross-platform product shell with a spacious card dashboard.',
      chinese: 'Dashboard 布局：跨平台产品壳，宽松卡片式工作台。',
    ),
    styleIdentity: 'spacious-card-dashboard',
    isDefault: false,
    selectable: false,
  );

  static final List<LayoutProfileDescriptor> profiles = List.unmodifiable([
    messaging,
    dashboard,
  ]);

  static final Set<ClientSection> desktopDestinations = Set.unmodifiable(
    ClientSection.values,
  );

  static const Set<ClientSection> mobileDestinations = {
    ClientSection.agents,
    ClientSection.mobileRelay,
    ClientSection.settings,
  };

  static Set<ClientSection> destinationsFor(LayoutRuntimeSurface surface) =>
      surface == LayoutRuntimeSurface.mobile
      ? mobileDestinations
      : desktopDestinations;

  static final List<LayoutVariantCoverage> variants = List.unmodifiable([
    for (final profile in profiles)
      for (final surface in LayoutRuntimeSurface.values)
        for (final viewport in LayoutViewportPolicy.supportedFor(surface))
          LayoutVariantCoverage(
            key: LayoutVariantKey(
              profileId: profile.id,
              surface: surface,
              viewport: viewport,
            ),
            destinations: destinationsFor(surface),
          ),
  ]);

  static final Set<LayoutStateNamespace> messagingDesktopStateNamespaces =
      _stateNamespaces(
        messaging,
        LayoutRuntimeSurface.desktop,
        desktopMessagingExtras: true,
      );
  static final Set<LayoutStateNamespace> messagingMobileStateNamespaces =
      _stateNamespaces(messaging, LayoutRuntimeSurface.mobile);
  static final Set<LayoutStateNamespace> dashboardDesktopStateNamespaces =
      _stateNamespaces(dashboard, LayoutRuntimeSurface.desktop);
  static final Set<LayoutStateNamespace> dashboardMobileStateNamespaces =
      _stateNamespaces(dashboard, LayoutRuntimeSurface.mobile);

  static final Set<LayoutStateNamespace> stateNamespaces = Set.unmodifiable({
    ...messagingDesktopStateNamespaces,
    ...messagingMobileStateNamespaces,
    ...dashboardDesktopStateNamespaces,
    ...dashboardMobileStateNamespaces,
  });

  static Set<LayoutStateNamespace> _stateNamespaces(
    LayoutProfileDescriptor profile,
    LayoutRuntimeSurface surface, {
    bool desktopMessagingExtras = false,
  }) => Set.unmodifiable({
    LayoutStateNamespace(
      profileId: profile.id,
      surface: surface,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: profile.id,
      surface: surface,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: profile.id,
      surface: surface,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: profile.id,
      surface: surface,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
    if (desktopMessagingExtras) ...{
      LayoutStateNamespace(
        profileId: profile.id,
        surface: surface,
        destination: ClientSection.settings,
        channel: LayoutStateChannels.settingsIndex,
      ),
      LayoutStateNamespace(
        profileId: profile.id,
        surface: surface,
        destination: ClientSection.models,
        channel: LayoutStateChannels.communicationSection,
      ),
    },
  });
}
