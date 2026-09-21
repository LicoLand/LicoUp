import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_directive.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_destination_content.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_features_grid.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/destinations/desktop_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_bar.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/shell/desktop_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion_surface.dart';
import 'package:licoup/src/frontend/shared/messaging/external_conversation_composer.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_column.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';

/// Desktop shell: a two-pane workspace on the clear window veil. The left
/// pane hosts one content at a time (the 功能 grid, 设置, or an app); the
/// conversation occupies the right pane permanently. The full-width bottom
/// bar splits into the navigation icon strip (aligned under the left pane)
/// and the conversation composer (aligned under the conversation). The top
/// chrome row carries the traffic-light anchor — the only anchor reporter in
/// this profile — and the left-pane collapse toggle.
///
/// Collapsing the left pane runs one morph: the pane slides out to the left,
/// the conversation list grows in at the snapped icon-grid width, the icon
/// strip locks to that same width, and the composer box expands upward with
/// its Assistant / Adaptive Flywheel capsules popping in at its top-left.
Widget buildDesktopDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => DesktopDesktopShell(data: data);

Widget buildDesktopDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => DesktopDesktopShell(data: data);

/// What the left pane currently hosts.
sealed class _LeftContent {
  const _LeftContent();
}

final class _LeftGrid extends _LeftContent {
  const _LeftGrid();
}

final class _LeftSettings extends _LeftContent {
  const _LeftSettings();
}

final class _LeftApp extends _LeftContent {
  const _LeftApp(this.app);

  final DesktopAppId app;
}

final class DesktopDesktopShell extends StatefulWidget {
  const DesktopDesktopShell({super.key, required this.data, this.dockModel});

  final LayoutShellBuildContext data;

  /// Test seam; production shells own their model.
  final DesktopDockModel? dockModel;

  @override
  State<DesktopDesktopShell> createState() => _DesktopDesktopShellState();
}

final class _DesktopDesktopShellState extends State<DesktopDesktopShell> {
  late DesktopDockModel _dock;
  late bool _ownsDock;

  _LeftContent _leftContent = const _LeftGrid();
  bool _leftCollapsed = false;
  double _leftExtent = DesktopDesktopMetrics.leftPaneDefaultExtent;
  bool _leftDragging = false;

  /// Visited left destinations stay mounted in offstage slots, so switching
  /// never remounts a pane: no initState re-runs and each pane keeps its
  /// scroll and selection state.
  final Map<ClientSection, Widget> _destinationSlots =
      <ClientSection, Widget>{};

  /// The permanent conversation surface: the host-built agents destination
  /// once visited, otherwise the port-built embed.
  Widget? _conversationBase;

  /// Most-recently-launched open apps first; feeds the collapsed strip so the
  /// pinned minimum (设置 / 功能 / last app) always survives the narrowest
  /// snap. Session-scoped; the dock order itself stays user-owned.
  List<DesktopAppId> _recency = <DesktopAppId>[];

  bool _historyOpen = false;
  String? _openFolderId;

  /// While the conversation list edge is being dragged, the icon strip tracks
  /// it without animation; the debounce restores animated width changes.
  bool _listDragging = false;
  Timer? _listDragDebounce;

  /// Conversation-list extent in icon-grid slots. The raw drag position is
  /// tracked separately so snapping can hold until the next slot boundary.
  double _listExtent = DesktopDesktopMetrics.dockIconSlotsExtent(
    DesktopDesktopMetrics.dockMinIconSlots,
  );
  double _listExtentRaw = 0;
  bool _listExtentHydrated = false;

  @override
  void initState() {
    super.initState();
    _dock = widget.dockModel ?? DesktopDockModel();
    _ownsDock = widget.dockModel == null;
    _dock.addListener(_handleDockChanged);
    if (_dock.ready) {
      _seedRecency();
    } else {
      unawaited(_dock.load());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_destinationSynced) {
      _destinationSynced = true;
      _syncLeftContentFromDestination(widget.data.activeDestination);
    }
  }

  bool _destinationSynced = false;

  @override
  void didUpdateWidget(DesktopDesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.dockModel;
    if (next != null && !identical(next, _dock)) {
      _dock.removeListener(_handleDockChanged);
      if (_ownsDock) _dock.dispose();
      _dock = next;
      _ownsDock = false;
      _dock.addListener(_handleDockChanged);
      if (_dock.ready) {
        _seedRecency();
      } else {
        unawaited(_dock.load());
      }
    }
    if (oldWidget.data.activeDestination != widget.data.activeDestination) {
      _syncLeftContentFromDestination(widget.data.activeDestination);
    }
  }

  @override
  void dispose() {
    _listDragDebounce?.cancel();
    _dock.removeListener(_handleDockChanged);
    if (_ownsDock) _dock.dispose();
    super.dispose();
  }

  /// External navigation (restores, shortcuts, other features) drives the
  /// left pane: settings and app sections claim it (expanding the pane when
  /// collapsed); the conversation never does — it is permanent on the right.
  void _syncLeftContentFromDestination(ClientSection destination) {
    switch (destination) {
      case ClientSection.settings:
        _leftContent = const _LeftSettings();
        _leftCollapsed = false;
      case ClientSection.agents:
        break;
      case final section:
        _leftContent = _LeftApp(_appForSection(section));
        _leftCollapsed = false;
    }
  }

  DesktopAppId _appForSection(ClientSection section) {
    if (section == ClientSection.models) {
      final pane = LayoutScope.maybeOf(context)?.state.readIfDeclaredFor(
        ClientSection.models,
        LayoutStateChannels.communicationSection,
      );
      if (pane is LayoutTabState) return desktopModelsAppForPane(pane.index);
      return DesktopAppId.modelsGateway;
    }
    for (final app in DesktopAppId.values) {
      if (desktopAppSection(app) == section) return app;
    }
    return DesktopAppId.monitoring;
  }

  void _handleDockChanged() {
    if (!mounted) return;
    if (_recency.isEmpty && _dock.ready) {
      _seedRecency();
    }
    setState(() {
      _recency = [
        for (final app in _recency)
          if (_dock.isOpen(app)) app,
      ];
      if (_openFolderId != null &&
          !_dock.entries.any(
            (entry) =>
                entry is DesktopDockFolderEntry && entry.id == _openFolderId,
          )) {
        _openFolderId = null;
      }
      final visibleApp = switch (_leftContent) {
        _LeftApp(app: final app) => app,
        _ => null,
      };
      if (visibleApp != null && !_dock.isOpen(visibleApp)) {
        _leftContent = const _LeftGrid();
      }
    });
  }

  void _seedRecency() {
    // Entries append on launch, so the reverse dock order approximates
    // recency until the user launches apps in this session.
    final apps = <DesktopAppId>[];
    for (final entry in _dock.entries) {
      switch (entry) {
        case DesktopDockAppEntry(app: final app):
          apps.insert(0, app);
        case DesktopDockFolderEntry(children: final children):
          for (final app in children.reversed) {
            apps.remove(app);
            apps.insert(0, app);
          }
      }
    }
    _recency = apps;
  }

  void _noteLaunched(DesktopAppId app) {
    _recency.remove(app);
    _recency.insert(0, app);
  }

  void _writeModelsPane(DesktopAppId app) {
    final pane = desktopAppModelsPane(app);
    if (pane == null) return;
    LayoutScope.maybeOf(context)?.state.writeIfDeclaredFor(
      ClientSection.models,
      LayoutStateChannels.communicationSection,
      LayoutTabState(pane),
    );
  }

  void _openSettings() {
    _dismissOverlays();
    Tooltip.dismissAllToolTips();
    setState(() {
      _leftContent = const _LeftSettings();
      _leftCollapsed = false;
      if (_leftExtent < DesktopDesktopMetrics.leftPaneDefaultExtent) {
        _leftExtent = DesktopDesktopMetrics.leftPaneDefaultExtent;
      }
    });
    if (widget.data.activeDestination != ClientSection.settings) {
      widget.data.onSelectDestination(ClientSection.settings);
    }
  }

  void _openFeaturesGrid() {
    _dismissOverlays();
    Tooltip.dismissAllToolTips();
    setState(() {
      _leftContent = const _LeftGrid();
      _leftCollapsed = false;
    });
  }

  void _launchApp(DesktopAppId app) {
    _dismissOverlays();
    Tooltip.dismissAllToolTips();
    _noteLaunched(app);
    if (_dock.ready) _dock.openApp(app);
    _writeModelsPane(app);
    setState(() {
      _leftContent = _LeftApp(app);
      _leftCollapsed = false;
    });
    final section = desktopAppSection(app);
    if (widget.data.activeDestination != section) {
      widget.data.onSelectDestination(section);
    }
  }

  void _closeApp(DesktopAppId app) {
    _dismissOverlays();
    Tooltip.dismissAllToolTips();
    _dock.closeApp(app);
  }

  void _dismissOverlays() {
    if (_openFolderId == null) return;
    setState(() => _openFolderId = null);
  }

  void _openFolder(String folderId) {
    setState(() => _openFolderId = _openFolderId == folderId ? null : folderId);
  }

  void _toggleLeftPane() {
    _dismissOverlays();
    setState(() => _leftCollapsed = !_leftCollapsed);
  }

  void _toggleHistoryList() {
    setState(() => _historyOpen = !_historyOpen);
  }

  /// Snap a raw list extent to the icon-slot grid shared with the icon strip.
  double _snapListExtent(double raw, double maxExtent) {
    final slots =
        ((raw -
                    DesktopDesktopMetrics.dockBoxPaddingH * 2 +
                    DesktopDesktopMetrics.dockIconGap) /
                DesktopDesktopMetrics.dockIconSlot)
            .round()
            .clamp(DesktopDesktopMetrics.dockMinIconSlots, 64);
    return DesktopDesktopMetrics.dockIconSlotsExtent(slots)
        .clamp(
          DesktopDesktopMetrics.dockIconSlotsExtent(
            DesktopDesktopMetrics.dockMinIconSlots,
          ),
          maxExtent,
        )
        .toDouble();
  }

  void _resizeConversationList(double delta, double maxExtent) {
    _listExtentRaw =
        (_listExtentRaw == 0 ? _listExtent : _listExtentRaw) + delta;
    final snapped = _snapListExtent(_listExtentRaw, maxExtent);
    if (snapped == _listExtent) return;
    _listDragging = true;
    _listDragDebounce?.cancel();
    _listDragDebounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _listDragging = false);
    });
    setState(() => _listExtent = snapped);
    LayoutScope.maybeOf(context)?.state.writeIfDeclaredFor(
      ClientSection.agents,
      LayoutStateChannels.agentsSidebar,
      LayoutPaneExtentState(_listExtent),
    );
  }

  void _hydrateListExtent() {
    if (_listExtentHydrated) return;
    _listExtentHydrated = true;
    final stored = LayoutScope.maybeOf(context)?.state.readIfDeclaredFor(
      ClientSection.agents,
      LayoutStateChannels.agentsSidebar,
    );
    if (stored is LayoutPaneExtentState) {
      _listExtent = _snapListExtent(stored.extent, 960);
      _listExtentRaw = _listExtent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    assert(
      data.environment.surface == LayoutRuntimeSurface.desktop,
      'desktop_desktop_surface_invalid',
    );
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      return ColoredBox(color: context.layoutPalette.background);
    }
    _hydrateListExtent();

    final content = Semantics(
      key: const ValueKey<String>('desktop-desktop-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _dismissOverlays,
        },
        child: Focus(
          skipTraversal: true,
          child: Material(
            color: Colors.transparent,
            child: ConversationMotionHost(
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _buildWorkspace(context, constraints),
              ),
            ),
          ),
        ),
      ),
    );

    final features = LayoutChromeFeaturesScope.maybeOf(context);
    if (features == null) return content;
    return LicoToastHost(
      child: LicoToastNoticesListener(
        notices: features.notificationNotices,
        onActivate: features.activateOperationNotice,
        child: content,
      ),
    );
  }

  Widget _buildWorkspace(BuildContext context, BoxConstraints constraints) {
    final colors = context.layoutPalette;
    final width = constraints.maxWidth;
    final entries = _dock.entries;
    final activeDestination = widget.data.activeDestination;
    if (activeDestination != ClientSection.agents) {
      _destinationSlots[activeDestination] = widget.data.destination;
    }

    final maxLeft = math
        .max(
          0,
          width -
              DesktopDesktopMetrics.windowInset * 2 -
              DesktopDesktopMetrics.regionGap -
              DesktopDesktopMetrics.conversationMinExtent,
        )
        .toDouble();
    final leftMin = math.min(DesktopDesktopMetrics.leftPaneMinExtent, maxLeft);
    final baseLeft = _leftExtent.clamp(leftMin, maxLeft).toDouble();
    // The conversation list shares its width floor with the detail: never
    // wider than what leaves the detail its minimum extent.
    final maxListExtent = math
        .max(
          DesktopDesktopMetrics.dockIconSlotsExtent(
            DesktopDesktopMetrics.dockMinIconSlots,
          ),
          width -
              DesktopDesktopMetrics.windowInset * 2 -
              8 -
              360 -
              DesktopDesktopMetrics.regionGap,
        )
        .toDouble();
    final listExtent = math.min(_listExtent, maxListExtent);
    final historyShift = _historyOpen && !_leftCollapsed ? listExtent : 0.0;
    final openLeft = (baseLeft - historyShift)
        .clamp(math.min(240, maxLeft), maxLeft)
        .toDouble();
    final leftWidth = _leftCollapsed ? 0.0 : openLeft;

    final visibleApp = switch (_leftContent) {
      _LeftApp(app: final app) => app,
      _ => null,
    };
    final wantedSection = switch (_leftContent) {
      _LeftGrid() => null,
      _LeftSettings() => ClientSection.settings,
      _LeftApp(app: final app) => desktopAppSection(app),
    };
    // A locally requested destination arrives with the next host rebuild;
    // until its slot exists the grid keeps the pane from flashing empty.
    final visibleSection =
        wantedSection != null && _destinationSlots.containsKey(wantedSection)
        ? wantedSection
        : null;

    final folderEntry = _openFolderId == null
        ? null
        : entries
              .whereType<DesktopDockFolderEntry>()
              .where((entry) => entry.id == _openFolderId)
              .firstOrNull;

    return Stack(
      key: const Key('desktop-desktop-z-stack'),
      fit: StackFit.expand,
      children: [
        ColoredBox(
          key: const Key('desktop-window-veil'),
          color: DesktopDesktopGlass.veil(isDark: colors.isDark),
        ),
        Padding(
          padding: const EdgeInsets.only(
            top: DesktopDesktopMetrics.windowInset,
          ),
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DesktopDesktopMetrics.windowInset,
                  ),
                  child: Row(
                    key: const Key('desktop-main-area'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AnimatedContainer(
                        key: const Key('desktop-left-pane-viewport'),
                        duration: _leftDragging
                            ? Duration.zero
                            : context.motion(LicoMotion.medium),
                        curve: LicoMotion.emphasized,
                        width: leftWidth,
                        // The pane keeps its last open width while shrinking so
                        // the collapse reads as a slide-out, not a relayout;
                        // ClipRect hides the overflow. Content stays mounted
                        // (and keeps its state) at width 0.
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: 0,
                            maxWidth: openLeft,
                            child: SizedBox(
                              width: openLeft,
                              child: _buildLeftPane(context, visibleSection),
                            ),
                          ),
                        ),
                      ),
                      if (leftWidth > 0)
                        SizedBox(
                          width: DesktopDesktopMetrics.splitHandleExtent,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.resizeLeftRight,
                            child: GestureDetector(
                              key: const Key('desktop-split-handle'),
                              behavior: HitTestBehavior.opaque,
                              onHorizontalDragStart: (_) =>
                                  setState(() => _leftDragging = true),
                              onHorizontalDragUpdate: (details) {
                                final next = (_leftExtent + details.delta.dx)
                                    .clamp(
                                      DesktopDesktopMetrics.leftPaneMinExtent,
                                      maxLeft,
                                    )
                                    .toDouble();
                                if (next != _leftExtent) {
                                  setState(() => _leftExtent = next);
                                }
                              },
                              onHorizontalDragEnd: (_) =>
                                  setState(() => _leftDragging = false),
                              onHorizontalDragCancel: () =>
                                  setState(() => _leftDragging = false),
                            ),
                          ),
                        )
                      else
                        const SizedBox(
                          width: DesktopDesktopMetrics.splitHandleExtent,
                        ),
                      Expanded(
                        child: _buildConversationPane(
                          context,
                          listExtent: listExtent,
                          listVisible: _leftCollapsed || _historyOpen,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: DesktopDesktopMetrics.regionGap),
              _buildBottomBar(
                context,
                entries: entries,
                visibleApp: visibleApp,
                listExtent: listExtent,
              ),
            ],
          ),
        ),
        Positioned(
          left: DesktopDesktopMetrics.windowInset + 8,
          top:
              DesktopDesktopMetrics.windowInset +
              (DesktopDesktopMetrics.chromeRowExtent -
                      DesktopDesktopMetrics.trafficLightAnchorExtent) /
                  2,
          child: Row(
            key: const Key('desktop-chrome-row'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const DesktopTrafficLightAnchor(
                key: Key('desktop-main-traffic-light-anchor'),
                width: 96,
                height: DesktopDesktopMetrics.trafficLightAnchorExtent,
              ),
              const SizedBox(width: 8),
              _DesktopCollapseToggle(
                key: const Key('desktop-chrome-toggle'),
                collapsed: _leftCollapsed,
                onTap: _toggleLeftPane,
              ),
            ],
          ),
        ),
        if (folderEntry != null)
          Positioned.fill(
            child: DesktopDockFolderView(
              folderId: folderEntry.id,
              children: folderEntry.children,
              onLaunchApp: _launchApp,
              onDismiss: () => setState(() => _openFolderId = null),
            ),
          ),
      ],
    );
  }

  Widget _buildLeftPane(BuildContext context, ClientSection? visibleSection) {
    final colors = context.layoutPalette;
    return Container(
      key: const Key('desktop-left-pane'),
      decoration: continuousHairlineDecoration(
        color: DesktopDesktopGlass.cardFill(isDark: colors.isDark),
        borderRadius: BorderRadius.circular(DesktopDesktopMetrics.paneRadius),
        stroke: DesktopDesktopGlass.cardBorder(
          colors.line,
          isDark: colors.isDark,
        ),
        strokeWidth: 0.5,
        shadows: DesktopDesktopGlass.cardShadows(isDark: colors.isDark),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DesktopDesktopMetrics.paneRadius),
        child: Column(
          children: [
            const SizedBox(height: DesktopDesktopMetrics.chromeRowExtent),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: visibleSection != null,
                    child: TickerMode(
                      enabled: visibleSection == null,
                      child: DesktopFeaturesGrid(
                        key: const Key('desktop-features-grid'),
                        onLaunchApp: _launchApp,
                      ),
                    ),
                  ),
                  for (final section in _destinationSlots.keys)
                    Offstage(
                      offstage: visibleSection != section,
                      child: TickerMode(
                        enabled: visibleSection == section,
                        child: KeyedSubtree(
                          key: ValueKey<String>(
                            'desktop-left-slot-${section.name}',
                          ),
                          child: _destinationSlots[section]!,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationPane(
    BuildContext context, {
    required double listExtent,
    required bool listVisible,
  }) {
    final hostScope = LayoutScope.maybeOf(context);
    Widget base = _resolveConversationBase(context);
    if (hostScope != null) {
      // Re-scope the embedded workspace to the agents namespace so its layout
      // channels resolve the same no matter which destination is active.
      base = LayoutScope(
        profileId: hostScope.profileId,
        environment: hostScope.environment,
        restorationNamespace: hostScope.restorationNamespace,
        tokens: hostScope.tokens,
        state: LayoutScopedState(
          profileId: hostScope.state.profileId,
          surface: hostScope.state.surface,
          destination: ClientSection.agents,
          store: hostScope.state.statePort,
        ),
        child: base,
      );
    }
    return ClipRRect(
      key: const Key('desktop-conversation-pane'),
      borderRadius: BorderRadius.circular(DesktopDesktopMetrics.paneRadius),
      child: LayoutAgentsDirectiveScope(
        directive: LayoutAgentsDirective(
          sidebarCollapsed: !listVisible,
          selectLocalGroupWhenIdle: true,
          historyListOpen: _historyOpen,
          onToggleHistoryList: _leftCollapsed ? null : _toggleHistoryList,
        ),
        child: LayoutExternalComposerScope(
          hosted: true,
          hostedCapsules: _leftCollapsed,
          child: MessagingTrafficLightSuppression(
            reservedExtent: DesktopDesktopMetrics.chromeLeadingExtent,
            child: MessagingSidebarGeometryScope(
              width: listExtent,
              onResize: _resizeConversationList,
              child: base,
            ),
          ),
        ),
      ),
    );
  }

  Widget _resolveConversationBase(BuildContext context) {
    if (widget.data.activeDestination == ClientSection.agents) {
      _conversationBase = widget.data.destination;
    }
    final cached = _conversationBase;
    if (cached != null) return cached;
    final port = DesktopDestinationContentRegistry.contentPort;
    if (port == null) {
      return ColoredBox(
        key: const Key('desktop-conversation-unready'),
        color: Colors.transparent,
      );
    }
    final hostScope = LayoutScope.maybeOf(context);
    if (hostScope == null) {
      return const ColoredBox(
        key: Key('desktop-conversation-unready'),
        color: Colors.transparent,
      );
    }
    _conversationBase = buildDesktopAgentsDestination(
      context,
      LayoutDestinationBuildContext(
        environment: widget.data.environment,
        destination: ClientSection.agents,
        content: port,
        state: hostScope.state,
      ),
    );
    return _conversationBase!;
  }

  Widget _buildBottomBar(
    BuildContext context, {
    required List<DesktopDockEntry> entries,
    required DesktopAppId? visibleApp,
    required double listExtent,
  }) {
    final features = LayoutChromeFeaturesScope.maybeOf(context);
    final composer = features == null
        ? const SizedBox.shrink()
        : KeyedSubtree(
            key: const Key('desktop-dock-composer'),
            child: features.buildDockComposer(
              context,
              expanded: _leftCollapsed,
            ),
          );
    final bar = DesktopDockBar(
      entries: entries,
      openApps: _dock.openApps,
      selectedApp: _leftCollapsed ? null : visibleApp,
      settingsActive: !_leftCollapsed && _leftContent is _LeftSettings,
      featuresActive: !_leftCollapsed && _leftContent is _LeftGrid,
      collapsed: _leftCollapsed,
      collapsedStripExtent: listExtent,
      stripWidthDuration: _listDragging
          ? Duration.zero
          : context.motion(LicoMotion.medium),
      recencyApps: _recency,
      composer: composer,
      onOpenSettings: _openSettings,
      onOpenFeatures: _openFeaturesGrid,
      onLaunchApp: _launchApp,
      onCloseApp: _closeApp,
      onMoveEntry: (storageId, index) => _dock.moveEntry(storageId, index),
      onMergeEntries: (dragged, target) => _dock.mergeEntries(dragged, target),
      onOpenFolder: _openFolder,
      onExtractFromFolder: (folderId, app, index) =>
          _dock.extractFromFolder(folderId, app, insertIndex: index),
    );
    final barDuration = context.motion(LicoMotion.medium);
    // A zero-duration AnimatedSize re-dirties itself synchronously when its
    // child's height changes mid-layout (reduce motion); instant sizing needs
    // no wrapper at all.
    if (barDuration == Duration.zero) return bar;
    return AnimatedSize(
      duration: barDuration,
      curve: LicoMotion.emphasized,
      alignment: Alignment.bottomCenter,
      child: bar,
    );
  }
}

/// The chrome-row toggle that collapses or expands the left pane.
final class _DesktopCollapseToggle extends StatefulWidget {
  const _DesktopCollapseToggle({
    super.key,
    required this.collapsed,
    required this.onTap,
  });

  final bool collapsed;
  final VoidCallback onTap;

  @override
  State<_DesktopCollapseToggle> createState() => _DesktopCollapseToggleState();
}

final class _DesktopCollapseToggleState extends State<_DesktopCollapseToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final label = widget.collapsed
        ? DesktopDesktopCopy.expandLeftPaneTooltip(strings)
        : DesktopDesktopCopy.collapseLeftPaneTooltip(strings);
    final duration = context.motion(LicoMotion.micro);
    return Semantics(
      button: true,
      toggled: widget.collapsed,
      label: label,
      child: Tooltip(
        message: label,
        waitDuration: LicoMotion.tooltipWait,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: duration,
              curve: LicoMotion.standard,
              width: DesktopDesktopMetrics.collapseToggleExtent,
              height: DesktopDesktopMetrics.collapseToggleExtent,
              decoration: BoxDecoration(
                color: _hovered
                    ? DesktopDesktopGlass.hoverFill(isDark: colors.isDark)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                widget.collapsed
                    ? Icons.keyboard_double_arrow_right_rounded
                    : Icons.keyboard_double_arrow_left_rounded,
                size: 18,
                color: _hovered ? colors.text : colors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
