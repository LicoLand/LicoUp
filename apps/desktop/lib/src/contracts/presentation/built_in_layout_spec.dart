import 'layout_environment.dart';
import 'layout_profile.dart';
import 'layout_state_namespace.dart';
import 'layout_style.dart';
import 'layout_variant.dart';
import 'semantic_destination.dart';

/// Renderer-neutral facts for the built-in layout products.
///
/// Application state and Flutter registries consume this same catalog so
/// neither layer duplicates profile identity, coverage, or state channels.
abstract final class BuiltInLayoutSpec {
  /// Dashboard's plain arrangement: a slim navigation rail, a list
  /// column beside it, and the main view (the chat pane for Messages).
  static final LayoutStyleId dashboardPlainStyleId = LayoutStyleId.parse(
    'plain',
  );

  /// Dashboard's card arrangement: the floating sidebar card beside
  /// the main content region.
  static final LayoutStyleId dashboardCardStyleId = LayoutStyleId.parse('card');

  static final LayoutProfileDescriptor dashboard = LayoutProfileDescriptor(
    id: LayoutProfileId.parse('dashboard'),
    label: LayoutProfileCopy(english: 'Dashboard', chinese: '仪表盘'),
    description: LayoutProfileCopy(
      english:
          'Dashboard layout in two styles: the default plain style pairs a slim navigation rail with a list column and the main view; the card style keeps a left navigation card with the conversation list and a bottom tab bar.',
      chinese: 'Dashboard 布局提供两种样式：默认的平铺以窄导航栏搭配列表栏与主视图；卡片则保留左侧导航卡片、会话列表和底部标签栏。',
    ),
    styleIdentity: 'dashboard-channel-chat',
    isDefault: true,
    revision: 1,
    styles: [
      LayoutStyleDescriptor(
        id: dashboardPlainStyleId,
        label: LayoutProfileCopy(english: 'Plain', chinese: '平铺'),
      ),
      LayoutStyleDescriptor(
        id: dashboardCardStyleId,
        label: LayoutProfileCopy(english: 'Card', chinese: '卡片'),
      ),
    ],
    defaultStyleId: dashboardPlainStyleId,
  );

  static final LayoutProfileDescriptor desktop = LayoutProfileDescriptor(
    id: LayoutProfileId.parse('desktop'),
    label: LayoutProfileCopy(english: 'Desktop', chinese: '桌面'),
    description: LayoutProfileCopy(
      english:
          'Desktop layout: a work area on the left hosts one app or plugin window at a time above a floating dock you arrange yourself, beside a resizable chat sidebar that keeps the conversation on the right.',
      chinese:
          'Desktop 布局：左侧工作区一次承载一个应用或插件窗口，底部是可自行排列的浮动 Dock；右侧可调宽度的聊天侧栏常驻对话。',
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
    ClientSection.devices,
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

  /// Every desktop-surface profile exposes the desktop-only state channels
  /// (settings index and models pane selection) so the feature lists and the
  /// Desktop app store write pane selection through the same retained
  /// channel.
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
