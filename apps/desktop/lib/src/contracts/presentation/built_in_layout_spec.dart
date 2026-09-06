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
  static final LayoutProfileDescriptor dashboard = LayoutProfileDescriptor(
    id: LayoutProfileId.parse('dashboard'),
    label: LayoutProfileCopy(english: 'Dashboard', chinese: '仪表盘'),
    description: LayoutProfileCopy(
      english:
          'Dashboard layout: the default product shell with a left navigation card, a flat conversation list, participant-style chat flow, and agent runtime details tucked into a details panel.',
      chinese: 'Dashboard 布局：默认产品壳——左侧导航卡片、扁平会话列表、参与者式聊天流，智能体运行细节收进详情面板。',
    ),
    styleIdentity: 'dashboard-channel-chat',
    isDefault: true,
    revision: 1,
  );

  static final LayoutProfileDescriptor desktop = LayoutProfileDescriptor(
    id: LayoutProfileId.parse('desktop'),
    label: LayoutProfileCopy(english: 'Desktop', chinese: '桌面'),
    description: LayoutProfileCopy(
      english:
          'Desktop layout: a floating stretchable capsule dock and Launchpad-style glass app store over one spacious main canvas.',
      chinese: 'Desktop 布局：主画布上方可伸缩的悬浮胶囊 Dock 与 Launchpad 风格玻璃应用商店。',
    ),
    styleIdentity: 'spacious-card-desktop',
    isDefault: false,
    selectable: true,
    revision: 1,
  );

  static final List<LayoutProfileDescriptor> profiles = List.unmodifiable([
    dashboard,
    desktop,
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

  static final Set<LayoutStateNamespace> dashboardDesktopStateNamespaces =
      _stateNamespaces(dashboard, LayoutRuntimeSurface.desktop, extras: true);
  static final Set<LayoutStateNamespace> dashboardMobileStateNamespaces =
      _stateNamespaces(dashboard, LayoutRuntimeSurface.mobile);
  static final Set<LayoutStateNamespace> desktopDesktopStateNamespaces =
      _stateNamespaces(desktop, LayoutRuntimeSurface.desktop, extras: true);
  static final Set<LayoutStateNamespace> desktopMobileStateNamespaces =
      _stateNamespaces(desktop, LayoutRuntimeSurface.mobile);

  static final Set<LayoutStateNamespace> stateNamespaces = Set.unmodifiable({
    ...dashboardDesktopStateNamespaces,
    ...dashboardMobileStateNamespaces,
    ...desktopDesktopStateNamespaces,
    ...desktopMobileStateNamespaces,
  });

  /// Both desktop-surface profiles expose the desktop-only state channels
  /// (settings index and models pane selection) so the Dashboard navigation
  /// list and the Desktop app store write pane selection through the same
  /// retained channel.
  static Set<LayoutStateNamespace> _stateNamespaces(
    LayoutProfileDescriptor profile,
    LayoutRuntimeSurface surface, {
    bool extras = false,
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
    if (extras) ...{
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
