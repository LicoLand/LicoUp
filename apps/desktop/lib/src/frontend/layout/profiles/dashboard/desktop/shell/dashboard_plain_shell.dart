import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/layout_value_builder.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_plain_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_rail.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/mascot/self_mascot_identity.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_column.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_foundation.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/shared/ui/lico_list_typography.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_drag_region.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';

/// The selection light the plain Dashboard renders: dark presets take the
/// starlight light, light presets keep the lamp.
LicoSelectionTreatment dashboardPlainSelectionTreatment(
  LayoutPalette palette,
) => palette.isDark
    ? LicoSelectionTreatment.starlight
    : LicoSelectionTreatment.lamp;

/// The list typeface scale the plain Dashboard renders: dark presets grade
/// by information value, light presets keep the baseline literals.
LicoListTypography dashboardPlainListTypography(LayoutPalette palette) =>
    palette.isDark ? LicoListTypography.graded : LicoListTypography.baseline;

/// The Dashboard plain shell over the window's translucent backdrop: a slim
/// navigation rail, a draggable list column for list-hosted destinations and
/// the flat detail surface, separated only by hairlines. Rail and list
/// column paint no fill — they sit on the veil over the behind-window
/// vibrancy; the rail's top strip is the single traffic-light anchor and
/// the list column's first row is the centred search row, both sized so
/// their empty pixels drag the window. Notifications surface through the
/// shared floating toast.
Widget buildDashboardPlainShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _DashboardPlainShell(data: data);

final class _DashboardPlainShell extends StatefulWidget {
  const _DashboardPlainShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  State<_DashboardPlainShell> createState() => _DashboardPlainShellState();
}

final class _DashboardPlainShellState extends State<_DashboardPlainShell> {
  void _selectDestination(ClientSection destination) {
    widget.data.onSelectDestination(destination);
  }

  void _openRailSection(DashboardRailItem item) =>
      _selectDestination(switch (item) {
        DashboardRailItem.messages => ClientSection.agents,
        DashboardRailItem.agents => ClientSection.agentHub,
        // Agent Hub has its own rail entry, so the Features tab falls back to
        // the first feature-list destination rather than a feature host the
        // list itself hides.
        DashboardRailItem.features =>
          dashboardRailFeatureColumnHosts(widget.data.activeDestination)
              ? widget.data.activeDestination
              : ClientSection.models,
        DashboardRailItem.settings => ClientSection.settings,
      });

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
      typography: dashboardPlainListTypography(colors),
      child: LicoSelectionTreatmentScope(
        treatment: dashboardPlainSelectionTreatment(colors),
        child: Semantics(
          key: const ValueKey<String>('dashboard-plain-shell'),
          container: true,
          label: data.destinationLabel(data.activeDestination),
          child: colors.isDark
              // The galaxy covers the whole window in dark — rail, list and
              // detail read as nav glass / content glass planes over it.
              ? LicoWindowGround(
                  color: colors.background,
                  child: Material(
                    type: MaterialType.transparency,
                    child: _shellContent(data),
                  ),
                )
              : Material(color: colors.background, child: _shellContent(data)),
        ),
      ),
    );

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
    final colors = context.layoutPalette;
    return Semantics(
      key: ValueKey<String>(
        'dashboard-desktop-focus-${data.initialFocusTarget}',
      ),
      container: true,
      explicitChildNodes: true,
      child: MessagingTrafficLightSuppression(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: colors.isDark
                  ? LicoPaneGlass.navGlassFill
                  : Colors.transparent,
              child: SizedBox(
                width: DashboardPlainMetrics.railExtent,
                child: Stack(
                  children: [
                    // The drag region is the rail's top strip's bottom layer:
                    // the anchor claims no hits, so empty pixels drag the
                    // window and a double tap zooms it — under the lights
                    // the native buttons take their own clicks.
                    const Positioned(
                      key: Key('dashboard-plain-drag-strip'),
                      top: 0,
                      left: 0,
                      right: 0,
                      height: MessagingDesktopMetrics.sidebarTopRowExtent,
                      child: LicoWindowDragRegion(child: SizedBox.expand()),
                    ),
                    Column(
                      children: [
                        // The shell's single traffic-light anchor reporter:
                        // the rail's top strip gives the lights an equal top,
                        // bottom and left inset.
                        const SizedBox(
                          key: Key('dashboard-plain-light-strip'),
                          height: MessagingDesktopMetrics.sidebarTopRowExtent,
                          child: MessagingTrafficLightAnchor(
                            width: DashboardPlainMetrics.railExtent,
                            height: MessagingDesktopMetrics.sidebarTopRowExtent,
                          ),
                        ),
                        Expanded(
                          child: DashboardRail(
                            selected: dashboardRailItemFor(
                              data.activeDestination,
                            ),
                            selfMascotId: selfMascotIdentity.value,
                            onSelfMascotChanged: (id) =>
                                setState(() => selfMascotIdentity.value = id),
                            onSelect: _openRailSection,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: colors.isDark
                    ? LicoPaneGlass.navGlassFill
                    : Colors.transparent,
                child: LayoutChromePortScope(
                  chrome: data.chrome,
                  child: MessagingSidebarGeometry(
                    leadingExtent: DashboardPlainMetrics.railExtent,
                    child: _DashboardPlainWorkspace(
                      data: data,
                      onSelectDestination: _selectDestination,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The workspace beside the rail: a list column plus the flat detail for
/// list-hosted sections (Messages owns its own identical split inside its
/// destination; Settings hosts its section index here), or the detail
/// alone for the single-view sections.
final class _DashboardPlainWorkspace extends StatelessWidget {
  const _DashboardPlainWorkspace({
    required this.data,
    required this.onSelectDestination,
  });

  final LayoutShellBuildContext data;
  final ValueChanged<ClientSection> onSelectDestination;

  @override
  Widget build(BuildContext context) {
    final active = data.activeDestination;
    if (active == ClientSection.agents) {
      // Messages: the conversation workspace renders the same list column
      // plus flat detail arrangement through the plain agents presentation.
      return data.destination;
    }
    if (active == ClientSection.settings) {
      return MessagingSidebarColumn(
        key: const Key('dashboard-plain-sidebar'),
        presentation: dashboardPlainAgentsPresentation,
        sidebar: _DashboardPlainListColumn(
          destination: active,
          onSelectDestination: onSelectDestination,
        ),
        detail: _DashboardPlainDetail(child: data.destination),
      );
    }
    if (!dashboardRailFeatureColumnHosts(active)) {
      return _DashboardPlainDetail(child: data.destination);
    }
    return MessagingSidebarColumn(
      key: const Key('dashboard-plain-sidebar'),
      presentation: dashboardPlainAgentsPresentation,
      sidebar: _DashboardPlainListColumn(
        destination: active,
        onSelectDestination: onSelectDestination,
      ),
      detail: _DashboardPlainDetail(child: data.destination),
    );
  }
}

/// The plain detail surface: one solid flat fill from the window's top
/// edge, opaque and free of ambient effect — its ground owns the scope so
/// feature-owned grounds inside keep their fill but mount no second sky.
final class _DashboardPlainDetail extends StatelessWidget {
  const _DashboardPlainDetail({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    // Dark: the flat pane-glass veil over the shell's galaxy; light: the
    // solid detail fill — the shell's ground owns the window surface.
    // Material supplies the ink ancestor for the rows inside.
    return Material(
      color: colors.isDark ? LicoPaneGlass.paneGlassVeil : colors.background,
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// The list column beside the rail: the centred search row and the
/// destination's index list — Features hosts the feature order list,
/// Settings the section index bound to the shared section channel. The
/// rail owns navigation, so there is no bottom nav.
final class _DashboardPlainListColumn extends StatelessWidget {
  const _DashboardPlainListColumn({
    required this.destination,
    required this.onSelectDestination,
  });

  final ClientSection destination;
  final ValueChanged<ClientSection> onSelectDestination;

  @override
  Widget build(BuildContext context) {
    final chrome = LayoutChromePortScope.maybeOf(context);
    return MessagingSidebarFoundation(
      topSearchRow: true,
      onSearch: chrome == null
          ? null
          : () => unawaited(chrome.openGlobalSearch(context)),
      list: destination == ClientSection.settings
          ? const _DashboardPlainSettingsList()
          : MessagingFeatureSidebarList(
              current: destination,
              onSelectDestination: onSelectDestination,
              excludedItems: const {MessagingFeatureItem.agentHub},
            ),
    );
  }
}

/// The Settings section index inside the list column. It follows the same
/// `LayoutStateChannels.settingsSection` channel the settings content
/// reads — selecting a row scrolls the content, scrolling moves the
/// selection.
final class _DashboardPlainSettingsList extends StatelessWidget {
  const _DashboardPlainSettingsList();

  @override
  Widget build(BuildContext context) {
    final scopedState = LayoutScope.of(context).state;
    return LayoutValuesBuilder(
      state: scopedState,
      valuesOf: (context) => [messagingSettingsSectionIndex(scopedState)],
      builder: (context) => MessagingSettingsSectionList(
        selectedIndex: messagingSettingsSectionIndex(scopedState),
        onSelectIndex: (index) => scopedState.writeIfDeclared(
          LayoutStateChannels.settingsSection,
          LayoutTabState(index),
        ),
      ),
    );
  }
}
