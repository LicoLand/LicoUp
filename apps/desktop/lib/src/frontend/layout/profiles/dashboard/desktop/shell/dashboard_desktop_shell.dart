import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_content_region.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_main_content_card.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_profile_page.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_sidebar_column.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';

/// Dashboard desktop shell hierarchy: one frosted-glass content region whose
/// rounded main card carries the navigation sidebar — the macOS traffic
/// lights sit at the sidebar card top-left (or at the main card top-left on
/// full-width destinations). There is no top chrome band; notifications
/// surface through the shared floating toast.
Widget buildDashboardDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _DashboardDesktopShell(data: data);

Widget buildDashboardDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _DashboardDesktopShell(data: data);

final class _DashboardDesktopShell extends StatefulWidget {
  const _DashboardDesktopShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  State<_DashboardDesktopShell> createState() => _DashboardDesktopShellState();
}

final class _DashboardDesktopShellState extends State<_DashboardDesktopShell> {
  bool _profileOpen = false;
  ValueNotifier<bool>? _auxPanelOpen;

  void _closeProfile() {
    final notifier = _auxPanelOpen;
    if (notifier != null) {
      if (notifier.value) {
        notifier.value = false;
      }
      return;
    }
    if (_profileOpen) {
      setState(() => _profileOpen = false);
    }
  }

  void _selectDestination(ClientSection destination) {
    _closeProfile();
    widget.data.onSelectDestination(destination);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final colors = context.layoutPalette;
    assert(
      data.environment.surface == LayoutRuntimeSurface.desktop,
      'dashboard_desktop_surface_invalid',
    );
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      return ColoredBox(color: colors.background);
    }
    final notifier = LayoutChromeFeaturesScope.maybeOf(
      context,
    )?.auxChromePanelOpen;
    if (!identical(_auxPanelOpen, notifier)) {
      _auxPanelOpen = notifier;
    }

    final content = Semantics(
      key: const ValueKey<String>('dashboard-desktop-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _closeProfile,
        },
        child: Focus(
          skipTraversal: true,
          child: Material(
            // Transparent base: the native NSVisualEffectView blurs the
            // desktop beneath every chrome region and margin gutter.
            color: Colors.transparent,
            child: notifier == null
                ? _shellContent(data, profileOpen: _profileOpen)
                : ValueListenableBuilder<bool>(
                    valueListenable: notifier,
                    builder: (context, open, _) =>
                        _shellContent(data, profileOpen: open),
                  ),
          ),
        ),
      ),
    );

    // Mount the unified toast host and the chrome-notices listener (frozen
    // toast contract): notifications surface as floating toasts now that the
    // chrome band and its bell are gone.
    final features = LayoutChromeFeaturesScope.maybeOf(context);
    if (features == null) {
      return content;
    }
    return LicoToastHost(
      child: LicoToastNoticesListener(
        notices: features.notificationNotices,
        child: content,
      ),
    );
  }

  Widget _shellContent(
    LayoutShellBuildContext data, {
    required bool profileOpen,
  }) {
    return DashboardContentRegion(
      child: DashboardMainContentCard(
        child: _mainCardBody(data, profileOpen: profileOpen),
      ),
    );
  }

  Widget _mainCardBody(
    LayoutShellBuildContext data, {
    required bool profileOpen,
  }) {
    return Semantics(
      key: ValueKey<String>(
        'dashboard-desktop-focus-${data.initialFocusTarget}',
      ),
      container: true,
      explicitChildNodes: true,
      child: profileOpen
          ? DashboardProfilePage(
              onOpenPairing: () =>
                  _selectDestination(ClientSection.mobileRelay),
              onOpenSettings: () => _selectDestination(ClientSection.settings),
            )
          : LayoutChromePortScope(
              chrome: data.chrome,
              child: MessagingSidebarGeometry(
                child: _destinationWithSidebar(data),
              ),
            ),
    );
  }

  Widget _destinationWithSidebar(LayoutShellBuildContext data) {
    final destination = data.activeDestination;
    // Agents renders the conversation list through the same column widget,
    // reading width from MessagingSidebarGeometry; its contact-list
    // foundation carries the traffic-light row. Monitoring is full-width and
    // gets a shell light row over the main card top-left instead. Other
    // hosted destinations keep that column so width does not jump.
    if (!messagingSidebarKeepsColumn(destination)) {
      if (destination == ClientSection.agents) {
        return data.destination;
      }
      return Stack(
        key: const Key('dashboard-desktop-fullwidth-destination'),
        fit: StackFit.expand,
        children: [
          data.destination,
          const Positioned(
            left: MessagingDesktopMetrics.conversationListCardInset,
            top: MessagingDesktopMetrics.conversationListCardInset,
            child: MessagingTrafficLightAnchor(
              key: Key('dashboard-shell-traffic-light-row'),
            ),
          ),
        ],
      );
    }
    return MessagingSidebarColumn(
      presentation: dashboardDesktopAgentsPresentation,
      sidebar: MessagingDesktopNavSidebar(
        destination: destination,
        onSelectDestination: _selectDestination,
      ),
      detail: data.destination,
    );
  }
}
