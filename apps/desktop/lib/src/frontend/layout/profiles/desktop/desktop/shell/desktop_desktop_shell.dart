import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_destination_content.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_bar.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/overlay/desktop_floating_card.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/overlay/desktop_launchpad.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/shell/desktop_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/messaging/external_conversation_composer.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// Desktop shell builders: one huge main area with a floating stretchable
/// capsule dock below.
Widget buildDesktopDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => DesktopDesktopShell(data: data);

Widget buildDesktopDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => DesktopDesktopShell(data: data);

/// Which fullscreen-exclusive app the main area currently hosts. Any other
/// active destination (for example one restored from another profile's
/// current-view state) is hosted as a plain fullscreen surface until the
/// user drives the dock.
enum DesktopFullscreenApp { conversation, settings, hosted }

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
  final List<DesktopAppId> _floatingStack = <DesktopAppId>[];
  final Map<DesktopAppId, Rect> _floatingRects = <DesktopAppId, Rect>{};
  BoxConstraints? _lastConstraints;
  bool _restoredFloating = false;
  bool _launchpadOpen = false;
  String? _openFolderId;
  int _cascadeCounter = 0;

  @override
  void initState() {
    super.initState();
    _dock = widget.dockModel ?? DesktopDockModel();
    _ownsDock = widget.dockModel == null;
    _dock.addListener(_handleDockChanged);
    if (_dock.ready) {
      _restoreFloating();
    } else {
      unawaited(_dock.load());
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
      _restoredFloating = false;
      _dock.addListener(_handleDockChanged);
      if (_dock.ready) {
        _restoreFloating();
      } else {
        unawaited(_dock.load());
      }
    }
  }

  @override
  void dispose() {
    _dock.removeListener(_handleDockChanged);
    if (_ownsDock) _dock.dispose();
    super.dispose();
  }

  DesktopFullscreenApp get _fullscreenApp =>
      switch (widget.data.activeDestination) {
        ClientSection.settings => DesktopFullscreenApp.settings,
        ClientSection.agents => DesktopFullscreenApp.conversation,
        _ => DesktopFullscreenApp.hosted,
      };

  void _handleDockChanged() {
    if (!mounted) return;
    if (!_restoredFloating && _dock.ready) {
      _restoreFloating();
    }
    final openApps = _dock.openApps;
    final removed = <DesktopAppId>[];
    for (final app in _floatingStack) {
      if (!openApps.contains(app)) removed.add(app);
    }
    if (removed.isNotEmpty) {
      for (final app in removed) {
        _floatingStack.remove(app);
        _floatingRects.remove(app);
      }
      if (_openFolderId != null &&
          !_dock.entries.any(
            (entry) =>
                entry is DesktopDockFolderEntry && entry.id == _openFolderId,
          )) {
        _openFolderId = null;
      }
    }
    setState(() {});
  }

  void _restoreFloating() {
    _restoredFloating = true;
    for (final entry in _dock.entries) {
      switch (entry) {
        case DesktopDockAppEntry(app: final app):
          _restoreApp(app);
        case DesktopDockFolderEntry(children: final children):
          for (final app in children) {
            _restoreApp(app);
          }
      }
    }
  }

  void _restoreApp(DesktopAppId app) {
    if (!desktopAppIsFloating(app) || _floatingStack.contains(app)) return;
    _floatingStack.add(app);
    _floatingRects[app] = _nextCascadeRect();
  }

  Rect _nextCascadeRect() {
    final step =
        (_cascadeCounter++ % 6) * DesktopDesktopMetrics.floatingCardCascadeStep;
    return Rect.fromLTWH(
      120 + step,
      88 + step,
      DesktopDesktopMetrics.floatingCardWidth,
      DesktopDesktopMetrics.floatingCardHeight,
    );
  }

  Rect _clampedRect(Rect rect, BoxConstraints constraints) {
    final width = math.min(rect.width, constraints.maxWidth - 48);
    final height = math.min(
      rect.height,
      constraints.maxHeight - DesktopDesktopMetrics.mainAreaBottomInset - 24,
    );
    final left = rect.left
        .clamp(12.0, math.max(12.0, constraints.maxWidth - width - 12))
        .toDouble();
    final top = rect.top
        .clamp(
          12.0,
          math.max(
            12.0,
            constraints.maxHeight -
                height -
                DesktopDesktopMetrics.mainAreaBottomInset,
          ),
        )
        .toDouble();
    return Rect.fromLTWH(left, top, width, height);
  }

  void _moveApp(DesktopAppId app, Offset delta) {
    final rect = _floatingRects[app];
    if (rect == null) return;
    // Clamp while accumulating: an unclamped store would let the rect drift
    // past the render clamp and swallow that much reverse drag before the
    // card visibly moves again.
    var next = rect.shift(delta);
    final constraints = _lastConstraints;
    if (constraints != null) {
      next = _clampedRect(next, constraints);
    }
    setState(() => _floatingRects[app] = next);
  }

  void _openSettings() {
    _dismissOverlays();
    if (widget.data.activeDestination != ClientSection.settings) {
      widget.data.onSelectDestination(ClientSection.settings);
    }
  }

  void _openConversation() {
    _dismissOverlays();
    if (_dock.ready) _dock.openApp(DesktopAppId.conversation);
    if (widget.data.activeDestination != ClientSection.agents) {
      widget.data.onSelectDestination(ClientSection.agents);
    }
  }

  void _launchApp(DesktopAppId app) {
    _dismissOverlays();
    if (app == DesktopAppId.conversation) {
      _openConversation();
      return;
    }
    _writeModelsPane(app);
    if (_dock.ready) _dock.openApp(app);
    setState(() => _raiseInStack(app));
  }

  void _raiseApp(DesktopAppId app) {
    _writeModelsPane(app);
    setState(() => _raiseInStack(app));
  }

  void _raiseInStack(DesktopAppId app) {
    _floatingStack.remove(app);
    _floatingStack.add(app);
    _floatingRects.putIfAbsent(app, _nextCascadeRect);
  }

  void _closeApp(DesktopAppId app) {
    if (app == DesktopAppId.conversation &&
        _fullscreenApp == DesktopFullscreenApp.conversation) {
      return;
    }
    _dismissOverlays();
    _dock.closeApp(app);
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
    if (!_launchpadOpen && _openFolderId == null) return;
    setState(() {
      _launchpadOpen = false;
      _openFolderId = null;
    });
  }

  void _toggleAppStore() {
    setState(() {
      _launchpadOpen = !_launchpadOpen;
      _openFolderId = null;
    });
  }

  void _openFolder(String folderId) {
    setState(() {
      _openFolderId = _openFolderId == folderId ? null : folderId;
      _launchpadOpen = false;
    });
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
    // Keep the 对话 entry present while the conversation fullscreen app is
    // active, matching macOS Dock running-app semantics.
    if (_fullscreenApp == DesktopFullscreenApp.conversation &&
        _dock.ready &&
        !_dock.isOpen(DesktopAppId.conversation)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_dock.isOpen(DesktopAppId.conversation)) {
          _dock.openApp(DesktopAppId.conversation);
        }
      });
    }

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
            child: LayoutBuilder(
              builder: (context, constraints) => _buildZStack(
                context,
                constraints,
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
        child: content,
      ),
    );
  }

  Widget _buildZStack(BuildContext context, BoxConstraints constraints) {
    _lastConstraints = constraints;
    final entries = _dock.entries;
    final maxBarWidth =
        (constraints.maxWidth - DesktopDesktopMetrics.dockBarSideInset * 2)
            .clamp(0.0, DesktopDesktopMetrics.dockBarMaxWidth);
    final barWidth = desktopDockBarWidth(
      maxWidth: maxBarWidth,
      entryCount: entries.length,
    );
    final fullscreenApp = _fullscreenApp;
    final composerMode = fullscreenApp == DesktopFullscreenApp.conversation;
    final inputBottomInset =
        DesktopDesktopMetrics.dockBarBottomInset +
        (composerMode ? 3 : (DesktopDesktopMetrics.dockBarHeight - 44) / 2);

    final folderEntry = _openFolderId == null
        ? null
        : entries
              .whereType<DesktopDockFolderEntry>()
              .where((entry) => entry.id == _openFolderId)
              .firstOrNull;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: _buildMainArea(context)),
        if (fullscreenApp != DesktopFullscreenApp.settings)
          const Positioned(
            left: 10,
            top: 8,
            child: DesktopTrafficLightAnchor(
              key: Key('desktop-main-traffic-light-anchor'),
            ),
          ),
        for (final app in _floatingStack)
          DesktopFloatingCard(
            key: ValueKey<String>('desktop-floating-card-${app.name}'),
            app: app,
            rect: _clampedRect(_floatingRects[app]!, constraints),
            onClose: () => _closeApp(app),
            onRaise: () => _raiseApp(app),
            onMove: (delta) => _moveApp(app, delta),
            child: _buildFloatingContent(context, app),
          ),
        if (_launchpadOpen)
          Positioned.fill(
            child: DesktopLaunchpad(
              onLaunchApp: _launchApp,
              onDismiss: () => setState(() => _launchpadOpen = false),
            ),
          ),
        if (folderEntry != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom:
                DesktopDesktopMetrics.dockBarBottomInset +
                DesktopDesktopMetrics.dockBarHeight +
                10,
            child: DesktopDockFolderView(
              folderId: folderEntry.id,
              children: folderEntry.children,
              onLaunchApp: _launchApp,
              onDismiss: () => setState(() => _openFolderId = null),
            ),
          ),
        Positioned.fill(
          child: DesktopDockBar(
            entries: entries,
            openApps: _dock.openApps,
            activeApp: composerMode ? DesktopAppId.conversation : null,
            settingsActive: fullscreenApp == DesktopFullscreenApp.settings,
            appStoreOpen: _launchpadOpen,
            onOpenSettings: _openSettings,
            onToggleAppStore: _toggleAppStore,
            onLaunchApp: _launchApp,
            onCloseApp: _closeApp,
            onMoveEntry: (storageId, index) =>
                _dock.moveEntry(storageId, index),
            onMergeEntries: (dragged, target) =>
                _dock.mergeEntries(dragged, target),
            onOpenFolder: _openFolder,
            onExtractFromFolder: (folderId, app, index) =>
                _dock.extractFromFolder(folderId, app, insertIndex: index),
          ),
        ),
        Positioned(
          right:
              (constraints.maxWidth - barWidth) / 2 +
              DesktopDesktopMetrics.dockIconGap,
          bottom: inputBottomInset,
          child: KeyedSubtree(
            key: const Key('desktop-dock-input'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DesktopDockConversationButton(
                  active: composerMode,
                  onTap: _openConversation,
                ),
                const SizedBox(width: DesktopDesktopMetrics.dockIconGap),
                SizedBox(
                  width: DesktopDesktopMetrics.dockInputWidth,
                  child: _buildInput(context, composerMode: composerMode),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMainArea(BuildContext context) {
    final data = widget.data;
    final colors = context.layoutPalette;
    final fullscreenApp = _fullscreenApp;
    final tint = switch (fullscreenApp) {
      DesktopFullscreenApp.conversation => Colors.transparent,
      DesktopFullscreenApp.settings => colors.surfaceLow.withValues(
        alpha: colors.isDark ? 0.20 : 0.28,
      ),
      DesktopFullscreenApp.hosted => colors.surfaceLow.withValues(
        alpha: colors.isDark ? 0.16 : 0.22,
      ),
    };
    Widget content = KeyedSubtree(
      key: const Key('desktop-main-area-content'),
      child: data.destination,
    );
    if (fullscreenApp == DesktopFullscreenApp.conversation) {
      content = LayoutExternalComposerScope(hosted: true, child: content);
    }
    return ColoredBox(
      key: const Key('desktop-main-area'),
      color: tint,
      child: Padding(
        padding: const EdgeInsets.only(
          bottom: DesktopDesktopMetrics.mainAreaBottomInset,
        ),
        child: content,
      ),
    );
  }

  Widget _buildFloatingContent(BuildContext context, DesktopAppId app) {
    final port = DesktopDestinationContentRegistry.contentPort;
    final section = desktopAppSection(app);
    final fallback = ColoredBox(
      key: ValueKey<String>('desktop-floating-missing-${app.name}'),
      color: context.layoutPalette.surface,
    );
    if (port == null) return fallback;
    Widget content = Builder(
      builder: (innerContext) => port.buildDestination(innerContext, section),
    );
    if (section == ClientSection.models) {
      // Pin the models pane per card: the shared ModelsPanel resolves its
      // pane from the models destination namespace, and two floating models
      // cards would otherwise re-target each other through the one retained
      // pane channel.
      final scope = LayoutScope.maybeOf(context);
      final paneIndex = desktopAppModelsPane(app);
      if (scope != null && paneIndex != null) {
        content = LayoutScope(
          profileId: scope.profileId,
          environment: scope.environment,
          restorationNamespace: scope.restorationNamespace,
          tokens: scope.tokens,
          state: LayoutScopedState(
            profileId: scope.state.profileId,
            surface: scope.state.surface,
            destination: ClientSection.models,
            store: _PinnedModelsPaneStatePort(scope.state.statePort, paneIndex),
          ),
          child: content,
        );
      }
    }
    return KeyedSubtree(
      key: ValueKey<String>('desktop-floating-content-${app.name}'),
      child: content,
    );
  }

  Widget _buildInput(BuildContext context, {required bool composerMode}) {
    if (composerMode) {
      final features = LayoutChromeFeaturesScope.maybeOf(context);
      if (features != null) {
        return KeyedSubtree(
          key: const Key('desktop-dock-input-composer'),
          child: features.buildDockComposer(context),
        );
      }
    }
    return _DesktopSearchCapsule(
      onTap: () => unawaited(widget.data.chrome.openGlobalSearch(context)),
    );
  }
}

/// The 对话 button pinned at the left of the input slot: activates the
/// conversation fullscreen app (and with it the composer input state).
final class _DesktopDockConversationButton extends StatefulWidget {
  const _DesktopDockConversationButton({
    required this.active,
    required this.onTap,
  });

  final bool active;
  final VoidCallback onTap;

  @override
  State<_DesktopDockConversationButton> createState() =>
      _DesktopDockConversationButtonState();
}

final class _DesktopDockConversationButtonState
    extends State<_DesktopDockConversationButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final label = strings.conversationListNav;
    final highlighted = widget.active || _hovered;
    return Semantics(
      button: true,
      selected: widget.active,
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
              key: const Key('desktop-dock-input-conversation'),
              duration: context.motion(LicoMotion.micro),
              width: DesktopDesktopMetrics.dockConversationButtonExtent,
              height: 44,
              decoration: BoxDecoration(
                color: _hovered
                    ? DesktopDesktopOnBlack.hoverOverlay
                    : desktopDesktopSurfaceBlack,
                borderRadius: BorderRadius.circular(
                  DesktopDesktopMetrics.dockInputRadius,
                ),
                border: Border.all(
                  color: widget.active
                      ? DesktopDesktopOnBlack.textSecondary
                      : DesktopDesktopOnBlack.line,
                  width: 0.5,
                ),
              ),
              child: Icon(
                Icons.chat_bubble_outline_rounded,
                size: 17,
                color: highlighted
                    ? DesktopDesktopOnBlack.text
                    : DesktopDesktopOnBlack.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The search/command visual state of the contextual input: a quiet rounded
/// rectangle on the same pure black surface as the bar that opens the global
/// search palette.
final class _DesktopSearchCapsule extends StatefulWidget {
  const _DesktopSearchCapsule({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_DesktopSearchCapsule> createState() => _DesktopSearchCapsuleState();
}

final class _DesktopSearchCapsuleState extends State<_DesktopSearchCapsule> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final hint = DesktopDesktopCopy.dockSearchHint(strings);
    return Semantics(
      button: true,
      label: hint,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            key: const Key('desktop-dock-input-search'),
            duration: context.motion(LicoMotion.micro),
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: desktopDesktopSurfaceBlack,
              borderRadius: BorderRadius.circular(
                DesktopDesktopMetrics.dockInputRadius,
              ),
              border: Border.all(
                color: _hovered
                    ? DesktopDesktopOnBlack.textMuted
                    : DesktopDesktopOnBlack.line,
                width: 0.5,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 17,
                  color: _hovered
                      ? DesktopDesktopOnBlack.text
                      : DesktopDesktopOnBlack.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DesktopDesktopOnBlack.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pins the retained models pane channel to one app's pane so two floating
/// models cards never re-target each other through the single shared channel.
final class _PinnedModelsPaneStatePort implements LayoutStatePort {
  const _PinnedModelsPaneStatePort(this._inner, this._paneIndex);

  final LayoutStatePort _inner;
  final int _paneIndex;

  bool _isPaneNamespace(LayoutStateNamespace namespace) =>
      namespace.destination == ClientSection.models &&
      namespace.surfaceId == LayoutStateChannels.communicationSection.id;

  @override
  Object get catalogIdentity => _inner.catalogIdentity;

  @override
  Stream<void> get changes => _inner.changes;

  @override
  bool declares(LayoutStateNamespace namespace) => _inner.declares(namespace);

  @override
  LayoutPresentationStateValue? read(LayoutStateNamespace namespace) =>
      _isPaneNamespace(namespace)
          ? LayoutTabState(_paneIndex)
          : _inner.read(namespace);

  @override
  void write(
    LayoutStateNamespace namespace,
    LayoutPresentationStateValue value,
  ) {
    if (_isPaneNamespace(namespace)) {
      return;
    }
    _inner.write(namespace, value);
  }

  @override
  void remove(LayoutStateNamespace namespace) {
    if (_isPaneNamespace(namespace)) {
      return;
    }
    _inner.remove(namespace);
  }
}
