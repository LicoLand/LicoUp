import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_card_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_sidebar_column.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_list_typography.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';

/// The selection light the card Dashboard renders: dark presets take the
/// starlight light, light presets keep the lamp.
LicoSelectionTreatment dashboardCardSelectionTreatment(LayoutPalette palette) =>
    palette.isDark
    ? LicoSelectionTreatment.starlight
    : LicoSelectionTreatment.lamp;

/// The list typeface scale the card Dashboard renders: dark presets grade
/// by information value, light presets keep the baseline literals.
LicoListTypography dashboardCardListTypography(LayoutPalette palette) =>
    palette.isDark ? LicoListTypography.graded : LicoListTypography.baseline;

/// Dashboard desktop shell hierarchy: destinations sit flush on the clear
/// window veil inside the chromeless main content region, while the sidebar
/// list is the single floating glass card (the macOS split-view idiom). The
/// sidebar chrome is unified — search capsule, list, and bottom nav stay put
/// while switching destinations. The traffic lights sit at the sidebar card
/// top-left (Agents hosts them in its conversation-list foundation). There
/// is no top chrome band; notifications surface through the shared floating
/// toast.
Widget buildDashboardCardShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _DashboardCardShell(data: data);

final class _DashboardCardShell extends StatefulWidget {
  const _DashboardCardShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  State<_DashboardCardShell> createState() => _DashboardCardShellState();
}

final class _DashboardCardShellState extends State<_DashboardCardShell> {
  /// Visited destinations stay mounted in offstage slots, so switching
  /// 功能/对话/设置 never unmounts a pane: no initState re-runs (no repeated
  /// refresh intents or store reloads), no first-build jank, and each pane
  /// keeps its scroll and selection state.
  final Map<ClientSection, Widget> _destinationSlots = {};

  /// The last sidebar-hosted destination, used to keep the shared column's
  /// sidebar props valid while 对话 (which hosts its own column) is active.
  ClientSection? _lastHostedDestination;

  void _selectDestination(ClientSection destination) {
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
    final content = LicoListTypographyScope(
      typography: dashboardCardListTypography(colors),
      child: LicoSelectionTreatmentScope(
        treatment: dashboardCardSelectionTreatment(colors),
        child: Semantics(
          key: const ValueKey<String>('dashboard-desktop-shell'),
          container: true,
          label: data.destinationLabel(data.activeDestination),
          child: Material(
            // Transparent base: the clear window veil in
            // DashboardContentRegion tints the desktop beneath chrome and
            // gutters without frosting it.
            color: Colors.transparent,
            child: _shellContent(data),
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
        onActivate: features.activateOperationNotice,
        child: content,
      ),
    );
  }

  Widget _shellContent(LayoutShellBuildContext data) {
    // One shell-level ground for the whole window: the galaxy in dark,
    // a solid cream in light — the sidebar card and the content card
    // float on it, and Messages' conversation sits directly on it.
    return LicoWindowGround(
      color: context.layoutPalette.background,
      child: _mainCardBody(data),
    );
  }

  Widget _mainCardBody(LayoutShellBuildContext data) {
    return Semantics(
      key: ValueKey<String>(
        'dashboard-desktop-focus-${data.initialFocusTarget}',
      ),
      container: true,
      explicitChildNodes: true,
      child: LayoutChromePortScope(
        chrome: data.chrome,
        child: MessagingSidebarGeometry(child: _destinationWithSidebar(data)),
      ),
    );
  }

  Widget _destinationWithSidebar(LayoutShellBuildContext data) {
    final active = data.activeDestination;
    _destinationSlots[active] = data.destination;
    if (active != ClientSection.agents) {
      _lastHostedDestination = active;
    }
    // Agents renders the conversation list through the same column widget,
    // reading width from MessagingSidebarGeometry; its contact-list
    // foundation carries the traffic-light row. Every other destination
    // shares one sidebar column; all visited panes stay mounted offstage so
    // switching only flips visibility, never remounts. Every slot carries its
    // key directly on the widget: slots appear lazily as destinations are
    // first visited, and only keyed children let the Stack insert a new slot
    // without remounting the ones already alive (a restored session can land
    // on a hosted destination and open 对话 later, inserting the agents slot
    // ahead of the shared column).
    final hostedSections = [
      for (final section in _destinationSlots.keys)
        if (section != ClientSection.agents) section,
    ];
    final agents = _destinationSlots[ClientSection.agents];
    return Stack(
      fit: StackFit.expand,
      children: [
        if (agents != null)
          _KeepAliveDestinationSlot(
            key: const ValueKey<String>('dashboard-destination-slot-agents'),
            active: active == ClientSection.agents,
            child: agents,
          ),
        if (hostedSections.isNotEmpty)
          _KeepAliveDestinationSlot(
            key: const ValueKey<String>(
              'dashboard-destination-slot-sidebar-column',
            ),
            active: active != ClientSection.agents,
            child: MessagingSidebarColumn(
              presentation: dashboardCardAgentsPresentation,
              sidebar: MessagingDesktopNavSidebar(
                destination: active == ClientSection.agents
                    ? _lastHostedDestination ?? active
                    : active,
                onSelectDestination: _selectDestination,
              ),
              detail: _DashboardCardContentCard(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final section in hostedSections)
                      _KeepAliveDestinationSlot(
                        key: ValueKey<String>(
                          'dashboard-destination-slot-${section.name}',
                        ),
                        active: section == active,
                        child: _destinationSlots[section]!,
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The floating content card every non-Messages destination sits in:
/// 10 px off the window's top/right/bottom and the sidebar card, radius
/// 14 concentric with the window corner — the same clear glass as the
/// Desktop panes (light black veil, thin rim, no smoke) in dark; the
/// light branch keeps the opaque cream fill.
final class _DashboardCardContentCard extends StatelessWidget {
  const _DashboardCardContentCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    // 10 px off the window's top/right/bottom and the sidebar card;
    // the resize handle overlays the leading 8 px of the gap.
    padding: const EdgeInsets.all(10),
    child: LicoPaneCard(
      key: const Key('dashboard-card-content-card'),
      borderRadius: BorderRadius.circular(14),
      child: child,
    ),
  );
}

/// One visited destination held alive while hidden: [Offstage] skips paint,
/// hit-testing, semantics, and test finders; [TickerMode] stops its
/// animations. Stream-driven content stays fresh, so re-entry is a
/// visibility flip instead of a remount.
final class _KeepAliveDestinationSlot extends StatelessWidget {
  const _KeepAliveDestinationSlot({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !active,
      child: TickerMode(enabled: active, child: child),
    );
  }
}
