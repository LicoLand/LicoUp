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
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/destinations/desktop_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_bar.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/shell/desktop_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion_surface.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';

/// Desktop shell: the work area on the left hosts one app at a time under a
/// shared 52px title row, with the floating dock at its bottom; the chat
/// sidebar on the right hosts the conversation permanently. The two rounded
/// cards sit over the window ground with a 12px gutter. The work-area title
/// row carries the traffic-light anchor, the only anchor reporter in this
/// profile.
Widget buildDesktopDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => DesktopDesktopShell(data: data);

Widget buildDesktopDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => DesktopDesktopShell(data: data);

final class DesktopDesktopShell extends StatefulWidget {
  const DesktopDesktopShell({super.key, required this.data, this.dockModel});

  final LayoutShellBuildContext data;

  /// Test seam; production shells own their model.
  final DesktopDockModel? dockModel;

  @override
  State<DesktopDesktopShell> createState() => _DesktopDesktopShellState();
}

/// An open dock context menu.
final class _DockMenu {
  const _DockMenu(this.item, this.left);

  final DesktopWorkItem item;

  /// Horizontal anchor inside the work area.
  final double left;
}

final class _DesktopDesktopShellState extends State<DesktopDesktopShell> {
  late DesktopDockModel _dock;
  late bool _ownsDock;

  LayoutChromeFeatures? _features;

  DesktopWorkItem _active = const DesktopWorkApp(desktopDefaultApp);

  /// The item the work area actually shows: [_active] once its content
  /// exists. A locally requested destination arrives with the next host
  /// rebuild; until then the previous item stays on screen.
  DesktopWorkItem _shown = const DesktopWorkApp(desktopDefaultApp);

  /// Running built-in apps, most recently opened first. Session-scoped;
  /// plugin windows report their own running state.
  final List<DesktopAppId> _running = <DesktopAppId>[desktopDefaultApp];

  /// Plugin windows opened this session, most recent first, for falling
  /// back when the active window closes.
  final List<String> _pluginRecency = <String>[];

  /// Visited destinations stay mounted in offstage slots, so switching never
  /// remounts an app: each keeps its scroll and selection state until it
  /// quits.
  final Map<ClientSection, Widget> _destinationSlots =
      <ClientSection, Widget>{};
  final Set<String> _mountedPlugins = <String>{};
  bool _collaborationMounted = false;

  /// The permanent conversation surface: the host-built agents destination
  /// once visited, otherwise the port-built embed.
  Widget? _conversationBase;

  String? _openFolderId;
  _DockMenu? _menu;
  final GlobalKey _workAreaKey = GlobalKey();
  final ValueNotifier<Widget?> _hostedPaneActions = ValueNotifier<Widget?>(
    null,
  );

  bool _sidebarCollapsed = false;
  bool _switcherOpen = false;
  double _sidebarExtent = DesktopDesktopMetrics.sidebarDefaultExtent;
  bool _sidebarDragging = false;
  bool _sidebarHydrated = false;
  bool _destinationSynced = false;

  @override
  void initState() {
    super.initState();
    _dock = widget.dockModel ?? DesktopDockModel();
    _ownsDock = widget.dockModel == null;
    _dock.addListener(_handleDockChanged);
    if (!_dock.ready) unawaited(_dock.load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final features = LayoutChromeFeaturesScope.maybeOf(context);
    if (!identical(features, _features)) {
      _features?.collaborationApp.removeListener(_handleFeaturesChanged);
      _features?.pluginWindows.removeListener(_handleFeaturesChanged);
      _features = features;
      features?.collaborationApp.addListener(_handleFeaturesChanged);
      features?.pluginWindows.addListener(_handleFeaturesChanged);
    }
    if (!_destinationSynced) {
      _destinationSynced = true;
      _syncFromDestination(widget.data.activeDestination);
      _shown = _active;
    }
  }

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
      if (!_dock.ready) unawaited(_dock.load());
    }
    if (!identical(oldWidget.data.content, widget.data.content)) {
      _conversationBase = null;
    }
    if (oldWidget.data.activeDestination != widget.data.activeDestination) {
      _syncFromDestination(widget.data.activeDestination);
    }
  }

  @override
  void dispose() {
    _features?.collaborationApp.removeListener(_handleFeaturesChanged);
    _features?.pluginWindows.removeListener(_handleFeaturesChanged);
    _dock.removeListener(_handleDockChanged);
    if (_ownsDock) _dock.dispose();
    super.dispose();
  }

  /// External navigation drives the work area: every destination except the
  /// conversation claims it. The conversation never does; it is permanent in
  /// the sidebar, so navigating there keeps the current app.
  void _syncFromDestination(ClientSection destination) {
    if (destination == ClientSection.agents) return;
    final app = _appForSection(destination);
    if (app == null) return;
    _active = DesktopWorkApp(app);
    _noteRunning(app);
  }

  DesktopAppId? _appForSection(ClientSection section) {
    if (section == ClientSection.models) {
      final pane = LayoutScope.maybeOf(context)?.state.readIfDeclaredFor(
        ClientSection.models,
        LayoutStateChannels.communicationSection,
      );
      if (pane is LayoutTabState) return desktopModelsAppForPane(pane.index);
      return DesktopAppId.modelsGateway;
    }
    return desktopAppForSection(section);
  }

  void _handleDockChanged() {
    if (!mounted) return;
    setState(() {
      if (_openFolderId != null &&
          !_dock.entries.any(
            (entry) =>
                entry is DesktopDockFolderEntry && entry.id == _openFolderId,
          )) {
        _openFolderId = null;
      }
    });
  }

  void _handleFeaturesChanged() {
    if (!mounted) return;
    final active = _active;
    if (active is DesktopWorkPlugin && !_pluginInstalled(active.pluginId)) {
      _mountedPlugins.remove(active.pluginId);
      _pluginRecency.remove(active.pluginId);
      _openFallback(excluding: active);
      return;
    }
    setState(() {});
  }

  bool _pluginInstalled(String pluginId) =>
      _features?.pluginWindows.value.any((plugin) => plugin.id == pluginId) ??
      false;

  bool _pluginRunning(String pluginId) =>
      _features?.pluginWindows.value.any(
        (plugin) => plugin.id == pluginId && plugin.open,
      ) ??
      false;

  void _noteRunning(DesktopAppId app) {
    _running
      ..remove(app)
      ..insert(0, app);
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

  void _dismissOverlays() {
    if (_openFolderId == null && _menu == null && !_switcherOpen) return;
    setState(() {
      _openFolderId = null;
      _menu = null;
      _switcherOpen = false;
    });
  }

  void _open(DesktopWorkItem item) {
    Tooltip.dismissAllToolTips();
    setState(() {
      _openFolderId = null;
      _menu = null;
      _active = item;
    });
    switch (item) {
      case DesktopWorkApp(app: final app):
        _noteRunning(app);
        _writeModelsPane(app);
        _selectDestination(desktopAppSection(app) ?? ClientSection.agents);
      case DesktopWorkPlugin(pluginId: final id):
        _pluginRecency
          ..remove(id)
          ..insert(0, id);
        _mountedPlugins.add(id);
        if (!_pluginRunning(id)) _features?.openPluginWindow(id);
        _selectDestination(ClientSection.agents);
    }
  }

  void _selectDestination(ClientSection section) {
    if (widget.data.activeDestination != section) {
      widget.data.onSelectDestination(section);
    }
  }

  void _quit(DesktopWorkItem item) {
    setState(() => _menu = null);
    switch (item) {
      case DesktopWorkApp(app: final app):
        if (app == desktopDefaultApp || !_running.contains(app)) return;
        _running.remove(app);
        final section = desktopAppSection(app);
        final shared = _running.any(
          (other) => desktopAppSection(other) == section,
        );
        if (section != null && !shared) {
          setState(() => _destinationSlots.remove(section));
        }
      case DesktopWorkPlugin(pluginId: final id):
        _pluginRecency.remove(id);
        setState(() => _mountedPlugins.remove(id));
        _features?.closePluginWindow(id);
    }
    if (_active == item) _openFallback(excluding: item);
  }

  /// Opens the most recently used running item other than [excluding], or
  /// the default app.
  void _openFallback({required DesktopWorkItem excluding}) {
    for (final app in _running) {
      final candidate = DesktopWorkApp(app);
      if (candidate != excluding) return _open(candidate);
    }
    for (final id in _pluginRecency) {
      final candidate = DesktopWorkPlugin(id);
      if (candidate != excluding && _pluginRunning(id)) {
        return _open(candidate);
      }
    }
    _open(const DesktopWorkApp(desktopDefaultApp));
  }

  void _openFolder(String folderId) {
    setState(() {
      _menu = null;
      _openFolderId = _openFolderId == folderId ? null : folderId;
    });
  }

  void _openMenu(DesktopWorkItem item, Offset globalPosition) {
    final box = _workAreaKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final local = box.globalToLocal(globalPosition);
    setState(() {
      _openFolderId = null;
      _menu = _DockMenu(item, local.dx);
    });
  }

  void _toggleSwitcher() => setState(() => _switcherOpen = !_switcherOpen);

  void _collapseSidebar() => setState(() {
    _sidebarCollapsed = true;
    _switcherOpen = false;
  });

  void _expandSidebar() => setState(() => _sidebarCollapsed = false);

  void _hydrateSidebarExtent() {
    if (_sidebarHydrated) return;
    _sidebarHydrated = true;
    final stored = LayoutScope.maybeOf(context)?.state.readIfDeclaredFor(
      ClientSection.agents,
      LayoutStateChannels.agentsSidebar,
    );
    if (stored is LayoutPaneExtentState) {
      _sidebarExtent = stored.extent
          .clamp(
            DesktopDesktopMetrics.sidebarMinExtent,
            DesktopDesktopMetrics.sidebarMaxExtent,
          )
          .toDouble();
    }
  }

  void _resizeSidebar(double delta, double maxExtent) {
    final next = (_sidebarExtent - delta)
        .clamp(DesktopDesktopMetrics.sidebarMinExtent, maxExtent)
        .toDouble();
    if (next == _sidebarExtent) return;
    setState(() => _sidebarExtent = next);
  }

  void _endSidebarResize() {
    setState(() => _sidebarDragging = false);
    LayoutScope.maybeOf(context)?.state.writeIfDeclaredFor(
      ClientSection.agents,
      LayoutStateChannels.agentsSidebar,
      LayoutPaneExtentState(_sidebarExtent),
    );
  }

  Future<void> _openQuickSwitcher() async {
    final features = _features;
    if (features == null) return;
    _dismissOverlays();
    final strings = LicoStrings.of(context);
    // Every app, not only the dock's: apps outside the dock (Skill Hub, Chat
    // Channels) are reached here and join the dock only while running.
    final apps = <LayoutQuickSwitcherApp>[
      for (final app in DesktopAppId.values)
        LayoutQuickSwitcherApp(
          id: DesktopWorkApp(app).id,
          label: desktopAppLabel(strings, app),
          icon: desktopAppIcon(app),
        ),
      for (final plugin in features.pluginWindows.value)
        LayoutQuickSwitcherApp(
          id: DesktopWorkPlugin(plugin.id).id,
          label: plugin.name,
          icon: Icons.web_asset_outlined,
        ),
    ];
    await features.openQuickSwitcher(
      context,
      apps: apps,
      onOpenApp: (id) {
        final item = desktopWorkItemById(id);
        if (item != null && mounted) _open(item);
      },
    );
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
    _hydrateSidebarExtent();

    final content = Semantics(
      key: const ValueKey<String>('desktop-desktop-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _dismissOverlays,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              unawaited(_openQuickSwitcher()),
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
              unawaited(_openQuickSwitcher()),
        },
        child: Focus(
          skipTraversal: true,
          child: Material(
            color: Colors.transparent,
            child: ConversationMotionHost(
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _buildWindow(context, constraints),
              ),
            ),
          ),
        ),
      ),
    );

    final features = _features;
    if (features == null) return content;
    return LicoToastHost(
      child: LicoToastNoticesListener(
        notices: features.notificationNotices,
        onActivate: features.activateOperationNotice,
        child: content,
      ),
    );
  }

  Widget _buildWindow(BuildContext context, BoxConstraints constraints) {
    final colors = context.layoutPalette;
    final activeDestination = widget.data.activeDestination;
    // A quit app's destination stays active until the host delivers the
    // fallback; only a running app's destination may (re)claim a slot.
    if (activeDestination != ClientSection.agents &&
        _running.any((app) => desktopAppSection(app) == activeDestination)) {
      _destinationSlots[activeDestination] = widget.data.destination;
    }
    final available =
        constraints.maxWidth -
        DesktopDesktopMetrics.windowInset * 2 -
        DesktopDesktopMetrics.paneGap;
    final maxSidebar = (available - DesktopDesktopMetrics.workAreaMinExtent)
        .clamp(
          DesktopDesktopMetrics.sidebarMinExtent,
          DesktopDesktopMetrics.sidebarMaxExtent,
        )
        .toDouble();
    final openExtent = _sidebarExtent
        .clamp(DesktopDesktopMetrics.sidebarMinExtent, maxSidebar)
        .toDouble();
    final sidebarWidth = _sidebarCollapsed
        ? DesktopDesktopMetrics.sidebarRailExtent
        : openExtent;

    // The window ground owns the preset's ambient effect: the two pane
    // cards are translucent glass over it, and nested conversation grounds
    // below paint no second sky.
    return LicoWindowGround(
      key: const Key('desktop-window-veil'),
      color: DesktopDesktopGlass.veil(colors),
      child: KeyedSubtree(
        key: const Key('desktop-desktop-z-stack'),
        child: Padding(
          padding: const EdgeInsets.all(DesktopDesktopMetrics.windowInset),
          child: Row(
            key: const Key('desktop-main-area'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildWorkArea(context)),
              _SidebarResizeHandle(
                enabled: !_sidebarCollapsed,
                onStart: () => setState(() => _sidebarDragging = true),
                onUpdate: (delta) => _resizeSidebar(delta, maxSidebar),
                onEnd: _endSidebarResize,
              ),
              AnimatedContainer(
                key: const Key('desktop-chat-sidebar-viewport'),
                duration: _sidebarDragging
                    ? Duration.zero
                    : context.motion(LicoMotion.medium),
                curve: LicoMotion.emphasized,
                width: sidebarWidth,
                child: _buildSidebar(context, sidebarWidth),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One window pane: the shared pane-card glass over the window ground.
  Widget _card({required Key key, required Widget child}) => LicoPaneCard(
    key: key,
    borderRadius: BorderRadius.circular(DesktopDesktopMetrics.paneRadius),
    child: child,
  );

  Widget _buildWorkArea(BuildContext context) {
    final features = _features;
    final shown = _resolveShown();
    final folder = _openFolderId == null
        ? null
        : _dock.entries
              .whereType<DesktopDockFolderEntry>()
              .where((entry) => entry.id == _openFolderId)
              .firstOrNull;
    final menu = _menu;
    return _card(
      key: const Key('desktop-work-area'),
      child: Stack(
        key: _workAreaKey,
        fit: StackFit.expand,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _WorkAreaTitleRow(
                item: shown,
                hostedActions: _hostedPaneActions,
                features: features,
                onOpenQuickSwitcher: features == null
                    ? null
                    : () => unawaited(_openQuickSwitcher()),
                onOpenPluginCenter: () =>
                    _open(const DesktopWorkApp(DesktopAppId.pluginCenter)),
                onClosePlugin: (id) => _quit(DesktopWorkPlugin(id)),
              ),
              Expanded(
                child: Padding(
                  key: const Key('desktop-work-area-content'),
                  padding: const EdgeInsets.only(
                    bottom: DesktopDesktopMetrics.dockReservedExtent,
                  ),
                  child: LicoPaneActionsHostScope(
                    actions: _hostedPaneActions,
                    child: _buildWorkAreaSlots(context, shown),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            left: DesktopDesktopMetrics.dockBottomInset,
            right: DesktopDesktopMetrics.dockBottomInset,
            bottom: DesktopDesktopMetrics.dockBottomInset,
            child: Center(child: _buildDock(context)),
          ),
          // The folder view stops above the dock so a child dragged out of
          // the folder can still reach the dock's drop gaps.
          if (folder != null)
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              bottom: DesktopDesktopMetrics.dockReservedExtent,
              child: DesktopDockFolderView(
                folderId: folder.id,
                children: folder.children,
                active: _active,
                onOpenApp: (app) => _open(DesktopWorkApp(app)),
                onDismiss: () => setState(() => _openFolderId = null),
              ),
            ),
          if (menu != null) ...[
            Positioned.fill(
              child: GestureDetector(
                key: const Key('desktop-dock-menu-barrier'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _menu = null),
                onSecondaryTap: () => setState(() => _menu = null),
              ),
            ),
            Positioned(
              left: math.max(8, menu.left - 24),
              bottom: DesktopDesktopMetrics.dockReservedExtent + 4,
              child: _DockContextMenu(entries: _menuEntries(menu.item)),
            ),
          ],
        ],
      ),
    );
  }

  DesktopWorkItem _resolveShown() {
    final active = _active;
    final ready = switch (active) {
      DesktopWorkApp(app: final app) =>
        desktopAppSection(app) == null ||
            _destinationSlots.containsKey(desktopAppSection(app)),
      DesktopWorkPlugin() => _features != null,
    };
    if (ready) _shown = active;
    return _shown;
  }

  Widget _buildWorkAreaSlots(BuildContext context, DesktopWorkItem shown) {
    final features = _features;
    final shownSection = switch (shown) {
      DesktopWorkApp(app: final app) => desktopAppSection(app),
      DesktopWorkPlugin() => null,
    };
    final collaborationVisible =
        shown == const DesktopWorkApp(DesktopAppId.collaboration);
    if (collaborationVisible) _collaborationMounted = true;
    if (shown case DesktopWorkPlugin(pluginId: final id)) {
      _mountedPlugins.add(id);
    }
    Widget slot({
      required String key,
      required bool visible,
      required Widget child,
    }) => Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: visible,
        child: KeyedSubtree(key: ValueKey<String>(key), child: child),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_collaborationMounted && features != null)
          slot(
            key: 'desktop-work-slot-collaboration',
            visible: collaborationVisible,
            child: features.buildCollaborationApp(context),
          ),
        for (final section in _destinationSlots.keys)
          slot(
            key: 'desktop-work-slot-${section.name}',
            visible: shownSection == section,
            child: _destinationSlots[section]!,
          ),
        if (features != null)
          for (final id in _mountedPlugins)
            if (_pluginInstalled(id))
              slot(
                key: 'desktop-work-slot-plugin-$id',
                visible: shown == DesktopWorkPlugin(id),
                child: features.buildPluginWindow(context, id),
              ),
      ],
    );
  }

  Widget _buildDock(BuildContext context) {
    final features = _features;
    final summaries =
        features?.pluginWindows.value ?? const <LayoutPluginWindowSummary>[];
    final byId = {for (final plugin in summaries) plugin.id: plugin};
    final plugins = <DesktopDockPlugin>[
      for (final id in _dock.pinnedPlugins)
        if (byId[id] case final plugin?)
          DesktopDockPlugin(id: id, name: plugin.name, running: plugin.open),
      for (final plugin in summaries)
        if (!_dock.isPluginPinned(plugin.id) &&
            (plugin.open || _active == DesktopWorkPlugin(plugin.id)))
          DesktopDockPlugin(
            id: plugin.id,
            name: plugin.name,
            running: plugin.open,
          ),
    ];
    final transient = [
      for (final app in DesktopAppId.values)
        if (!desktopDockApps.contains(app) &&
            !desktopDockSystemApps.contains(app) &&
            (_running.contains(app) || _active == DesktopWorkApp(app)))
          app,
    ];
    final running = <DesktopWorkItem>{
      for (final app in _running) DesktopWorkApp(app),
      for (final plugin in plugins)
        if (plugin.running) DesktopWorkPlugin(plugin.id),
    };
    final pending = features?.collaborationApp.value.pendingDecisions ?? 0;
    final dock = DesktopDockBar(
      entries: _dock.entries,
      transientApps: transient,
      plugins: plugins,
      active: _active,
      running: running,
      badges: {
        if (pending > 0)
          const DesktopWorkApp(DesktopAppId.collaboration): pending,
      },
      onOpen: _open,
      onMenu: _openMenu,
      onOpenFolder: _openFolder,
      onMoveEntry: (storageId, index) => _dock.moveEntry(storageId, index),
      onMergeEntries: (dragged, target) => _dock.mergeEntries(dragged, target),
      onExtractFromFolder: (folderId, app, index) =>
          _dock.extractFromFolder(folderId, app, insertIndex: index),
    );
    // The stored arrangement replaces the catalog default before the dock
    // first appears, so a restored order never visibly reshuffles.
    return IgnorePointer(
      ignoring: !_dock.ready,
      child: AnimatedOpacity(
        opacity: _dock.ready ? 1 : 0,
        duration: context.motion(LicoMotion.short),
        child: dock,
      ),
    );
  }

  List<_DockMenuEntry> _menuEntries(DesktopWorkItem item) {
    final strings = LicoStrings.of(context);
    return switch (item) {
      DesktopWorkApp(app: final app) => [
        _DockMenuEntry(
          key: 'open',
          label: DesktopDesktopCopy.dockOpen(strings),
          onSelected: () => _open(item),
        ),
        if (app != desktopDefaultApp && _running.contains(app))
          _DockMenuEntry(
            key: 'quit',
            label: DesktopDesktopCopy.dockQuit(strings),
            onSelected: () => _quit(item),
          ),
      ],
      DesktopWorkPlugin(pluginId: final id) => [
        _DockMenuEntry(
          key: 'open',
          label: DesktopDesktopCopy.dockOpen(strings),
          onSelected: () => _open(item),
        ),
        if (_pluginRunning(id))
          _DockMenuEntry(
            key: 'close',
            label: DesktopDesktopCopy.dockCloseWindow(strings),
            onSelected: () => _quit(item),
          ),
        if (_dock.isPluginPinned(id))
          _DockMenuEntry(
            key: 'remove',
            label: DesktopDesktopCopy.dockRemoveFromDock(strings),
            onSelected: () {
              setState(() => _menu = null);
              _dock.unpinPlugin(id);
            },
          )
        else
          _DockMenuEntry(
            key: 'keep',
            label: DesktopDesktopCopy.dockKeepInDock(strings),
            onSelected: () {
              setState(() => _menu = null);
              _dock.pinPlugin(id);
            },
          ),
      ],
    };
  }

  Widget _buildSidebar(BuildContext context, double width) {
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
    return _card(
      key: const Key('desktop-chat-sidebar'),
      // The content lays out at its target width while the card animates,
      // so neither mode ever renders squeezed between the two widths.
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: width,
        maxWidth: width,
        child: LayoutAgentsDirectiveScope(
          directive: LayoutAgentsDirective(
            sidebarMode: _sidebarCollapsed
                ? LayoutAgentsSidebarMode.avatarRail
                : LayoutAgentsSidebarMode.avatarColumn,
            selectLocalGroupWhenIdle: true,
            switcherOpen: _switcherOpen,
            onToggleSwitcher: _toggleSwitcher,
            onCollapseSidebar: _collapseSidebar,
            onExpandSidebar: _expandSidebar,
          ),
          child: MessagingTrafficLightSuppression(
            reservedExtent: 0,
            child: base,
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
        content: widget.data.content,
        state: hostScope.state,
        style: widget.data.style,
      ),
    );
    return _conversationBase!;
  }
}

/// The work-area title row: the traffic-light anchor, the current app's
/// tile, name and subtitle, and the app's actions on the right.
final class _WorkAreaTitleRow extends StatelessWidget {
  const _WorkAreaTitleRow({
    required this.item,
    required this.features,
    required this.onOpenQuickSwitcher,
    required this.onOpenPluginCenter,
    required this.onClosePlugin,
    this.hostedActions,
  });

  /// The destination's hosted title actions (published by
  /// [LicoPaneScaffold] panes); rendered in the right action slot.
  final ValueNotifier<Widget?>? hostedActions;

  final DesktopWorkItem item;
  final LayoutChromeFeatures? features;
  final VoidCallback? onOpenQuickSwitcher;
  final VoidCallback onOpenPluginCenter;
  final ValueChanged<String> onClosePlugin;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final features = this.features;
    final (
      IconData? icon,
      String name,
      String subtitle,
      Widget? actions,
    ) = switch (item) {
      DesktopWorkApp(app: final app) => (
        desktopAppIcon(app),
        desktopAppLabel(strings, app),
        app == DesktopAppId.collaboration
            ? features?.collaborationApp.value.subtitle ?? ''
            : '',
        null,
      ),
      DesktopWorkPlugin(pluginId: final id) => () {
        final summary = features?.pluginWindows.value
            .where((plugin) => plugin.id == id)
            .firstOrNull;
        return (
          null,
          summary?.name ?? id,
          DesktopDesktopCopy.pluginPublisher(
            strings,
            official: summary?.official ?? false,
          ),
          features?.buildPluginWindowActions(
            context,
            id,
            onOpenPermissionSettings: onOpenPluginCenter,
            onClose: () => onClosePlugin(id),
          ),
        );
      }(),
    };
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const Key('desktop-work-area-title-row'),
      height: DesktopDesktopMetrics.titleRowExtent,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colors.isDark
                ? const Color(0x0FFFFFFF)
                : const Color(0x12000000),
            width: 0.5,
          ),
        ),
      ),
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const DesktopTrafficLightAnchor(
            key: Key('desktop-main-traffic-light-anchor'),
          ),
          Container(
            key: const Key('desktop-work-area-title-icon'),
            width: DesktopDesktopMetrics.titleIconExtent,
            height: DesktopDesktopMetrics.titleIconExtent,
            alignment: Alignment.center,
            decoration: continuousHairlineDecoration(
              color: colors.isDark
                  ? const Color(0x0DFFFFFF)
                  : const Color(0x0A000000),
              borderRadius: BorderRadius.circular(8),
              stroke: colors.isDark
                  ? const Color(0x17FFFFFF)
                  : const Color(0x14000000),
              strokeWidth: 0.5,
            ),
            child: icon == null
                ? Text(
                    name.trim().isEmpty
                        ? '?'
                        : String.fromCharCode(
                            name.trim().runes.first,
                          ).toUpperCase(),
                    style: TextStyle(
                      color: colors.primaryStrong,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                : Icon(icon, size: 16, color: colors.primaryStrong),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: name,
                    style: TextStyle(
                      color: colors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    TextSpan(
                      text: ' · $subtitle',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                ],
              ),
              key: const Key('desktop-work-area-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleSmall?.copyWith(fontSize: 14),
            ),
          ),
          if (hostedActions != null)
            ValueListenableBuilder<Widget?>(
              valueListenable: hostedActions!,
              builder: (context, actions, _) =>
                  actions ?? const SizedBox.shrink(),
            ),
          ?actions,
          if (onOpenQuickSwitcher != null) ...[
            const SizedBox(width: 4),
            _TitleRowButton(
              key: const Key('desktop-quick-switcher-button'),
              icon: Icons.search_rounded,
              tooltip: DesktopDesktopCopy.quickSwitcherTooltip(strings),
              onTap: onOpenQuickSwitcher!,
            ),
          ],
        ],
      ),
    );
  }
}

final class _TitleRowButton extends StatefulWidget {
  const _TitleRowButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_TitleRowButton> createState() => _TitleRowButtonState();
}

final class _TitleRowButtonState extends State<_TitleRowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: LicoMotion.tooltipWait,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: context.motion(LicoMotion.micro),
              curve: LicoMotion.standard,
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _hovered
                    ? DesktopDesktopGlass.hoverFill(isDark: colors.isDark)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                widget.icon,
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

/// The drag handle in the gutter between the work area and the chat
/// sidebar. It paints only a short grip while hovered or dragged.
final class _SidebarResizeHandle extends StatefulWidget {
  const _SidebarResizeHandle({
    required this.enabled,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final bool enabled;
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final VoidCallback onEnd;

  @override
  State<_SidebarResizeHandle> createState() => _SidebarResizeHandleState();
}

final class _SidebarResizeHandleState extends State<_SidebarResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    if (!widget.enabled) {
      return const SizedBox(width: DesktopDesktopMetrics.paneGap);
    }
    return Semantics(
      label: DesktopDesktopCopy.resizeSidebarLabel(strings),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          key: const Key('desktop-sidebar-resize-handle'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            setState(() => _dragging = true);
            widget.onStart();
          },
          onHorizontalDragUpdate: (details) =>
              widget.onUpdate(details.delta.dx),
          onHorizontalDragEnd: (_) {
            setState(() => _dragging = false);
            widget.onEnd();
          },
          onHorizontalDragCancel: () {
            setState(() => _dragging = false);
            widget.onEnd();
          },
          child: SizedBox(
            width: DesktopDesktopMetrics.paneGap,
            child: Center(
              child: AnimatedContainer(
                duration: context.motion(LicoMotion.micro),
                width: 3,
                height: _hovered || _dragging ? 36 : 0,
                decoration: BoxDecoration(
                  color: colors.textMuted.withAlpha(_dragging ? 200 : 120),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@immutable
final class _DockMenuEntry {
  const _DockMenuEntry({
    required this.key,
    required this.label,
    required this.onSelected,
  });

  final String key;
  final String label;
  final VoidCallback onSelected;
}

/// The dock icon context menu: a small glass card above the dock.
final class _DockContextMenu extends StatelessWidget {
  const _DockContextMenu({required this.entries});

  final List<_DockMenuEntry> entries;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Container(
      key: const Key('desktop-dock-menu'),
      constraints: const BoxConstraints(minWidth: 168),
      padding: const EdgeInsets.all(5),
      decoration: continuousHairlineDecoration(
        color: DesktopDesktopGlass.dockFill(colors),
        borderRadius: BorderRadius.circular(12),
        stroke: LicoPaneGlass.cardBorder(colors.line, isDark: colors.isDark),
        strokeWidth: 0.5,
        shadows: DesktopDesktopGlass.dockShadows(isDark: colors.isDark),
      ),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final entry in entries) _DockMenuItem(entry: entry)],
        ),
      ),
    );
  }
}

final class _DockMenuItem extends StatefulWidget {
  const _DockMenuItem({required this.entry});

  final _DockMenuEntry entry;

  @override
  State<_DockMenuItem> createState() => _DockMenuItemState();
}

final class _DockMenuItemState extends State<_DockMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: ValueKey<String>('desktop-dock-menu-${widget.entry.key}'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.entry.onSelected,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _hovered ? colors.brandSurface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            widget.entry.label,
            style: TextStyle(
              color: colors.text,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
