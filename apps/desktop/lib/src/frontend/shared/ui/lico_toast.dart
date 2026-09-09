import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/apple_notifications.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Unified floating toast system for desktop layout shells (frozen contract:
/// better-plan layout-redesign, contract 3).
///
/// One caller-facing entry — [showLicoToast] — surfaces copy confirmations,
/// errors, and chrome notification notices through [LicoToastHost], which
/// paints a small auto-dismissing stack into the root [Overlay]. Desktop
/// shells mount the host and the notices listener near their root, in this
/// order so the listener and every feature panel sit below the host:
///
/// ```dart
/// LicoToastHost(
///   child: LicoToastNoticesListener(
///     notices: features.notificationNotices,
///     child: shellContent,
///   ),
/// )
/// ```
///
/// `notificationNotices` is the chrome notification-notices exposure (frozen
/// contract 4) produced by the binding chrome features as a
/// `ValueListenable<LicoToastNoticesSnapshot>`.
///
/// Surfaces without a host (mobile) keep the legacy path exactly:
/// [showLicoToast] falls back to [appleGlassSnackBar] through the ambient
/// [ScaffoldMessenger], so mobile rendering is byte-for-byte the old behavior.
enum LicoToastKind { info, success, error, notification }

/// How long a toast stays visible when the caller does not override it.
const Duration _defaultShowDuration = LicoMotion.toastDwell;

/// At most this many toasts stack at once; the oldest is evicted beyond it.
const int _maxVisibleToasts = 4;

/// One floating toast: glass capsule with a kind accent, dismissed by tap.
class LicoToast extends StatelessWidget {
  const LicoToast({
    super.key,
    required this.message,
    this.kind = LicoToastKind.info,
    this.icon,
    this.iconColor,
    this.onTap,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final LicoToastKind kind;

  /// Overrides the kind's default icon (for example the amber warning glyph
  /// the legacy bell used for warning severities).
  final IconData? icon;

  /// Overrides the kind's default accent color.
  final Color? iconColor;

  /// Tap handler; the host wires this to early dismissal.
  final VoidCallback? onTap;

  /// Distinct action from dismiss. Arrival never invokes this.
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final accent =
        iconColor ??
        switch (kind) {
          LicoToastKind.info => colors.textMuted,
          LicoToastKind.success => colors.success,
          LicoToastKind.error => colors.error,
          LicoToastKind.notification => colors.accent,
        };
    final iconData =
        icon ??
        switch (kind) {
          LicoToastKind.info => Icons.info_outline_rounded,
          LicoToastKind.success => Icons.check_circle_rounded,
          LicoToastKind.error => Icons.error_outline_rounded,
          LicoToastKind.notification => Icons.notifications_none_rounded,
        };
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AppleGlassSurface(
          borderRadius: BorderRadius.circular(
            AppleControlMetrics.menuCornerRadius,
          ),
          fillAlpha: colors.isDark ? 36 : 48,
          borderAlpha: colors.isDark ? 64 : 90,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(iconData, size: 16, color: accent),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(
                    message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.04,
                    ),
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(width: 10),
                  TextButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [message] as a unified floating toast.
///
/// When a [LicoToastHost] is mounted above [context] (desktop shells) the
/// toast joins the host's root-overlay stack. Without a host (mobile
/// surfaces) it routes to the legacy [appleGlassSnackBar], so mobile keeps
/// its exact previous rendering.
void showLicoToast(
  BuildContext context, {
  required String message,
  LicoToastKind kind = LicoToastKind.info,
  IconData? icon,
  Color? iconColor,
  Duration showDuration = _defaultShowDuration,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final host = LicoToastHost.maybeOf(context);
  if (host == null) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(appleGlassSnackBar(context: context, message: message));
    return;
  }
  host.show(
    message: message,
    kind: kind,
    icon: icon,
    iconColor: iconColor,
    showDuration: showDuration,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

/// Hosts the floating toast stack for a desktop shell.
///
/// Toasts render through a single root-[Overlay] entry — never a
/// [ScaffoldMessenger] snackbar — so they paint above hover popovers and do
/// not queue behind snackbars. The stack is bottom-anchored with the newest
/// toast lowest; each toast auto-dismisses after its duration and dismisses
/// early on tap. Only the toast capsules themselves are hit-testable, so the
/// stack never blocks the surface beneath.
class LicoToastHost extends StatefulWidget {
  const LicoToastHost({super.key, required this.child});

  final Widget child;

  /// The nearest host above [context], or null on surfaces without one.
  static LicoToastHostState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LicoToastHostScope>()?.state;

  @override
  State<LicoToastHost> createState() => LicoToastHostState();
}

class LicoToastHostState extends State<LicoToastHost> {
  final List<_LicoToastItem> _items = <_LicoToastItem>[];
  OverlayEntry? _stackEntry;
  int _nextToastId = 0;

  /// Shows [message] in the stack. A visible toast with the same message and
  /// kind is replaced by the fresh one instead of stacking a duplicate.
  void show({
    required String message,
    LicoToastKind kind = LicoToastKind.info,
    IconData? icon,
    Color? iconColor,
    Duration showDuration = _defaultShowDuration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    _items.removeWhere((item) => item.message == trimmed && item.kind == kind);
    _items.add(
      _LicoToastItem(
        id: _nextToastId++,
        message: trimmed,
        kind: kind,
        icon: icon,
        iconColor: iconColor,
        showDuration: showDuration,
        actionLabel: actionLabel,
        onAction: onAction,
      ),
    );
    while (_items.length > _maxVisibleToasts) {
      _items.removeAt(0);
    }
    _syncStackEntry();
  }

  void _dismissItem(int id) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _items.removeAt(index);
    _syncStackEntry();
  }

  void _syncStackEntry() {
    if (_items.isEmpty) {
      final entry = _stackEntry;
      _stackEntry = null;
      if (entry != null && entry.mounted) {
        entry.remove();
      }
      return;
    }
    final entry = _stackEntry;
    if (entry == null) {
      final created = OverlayEntry(builder: _buildStack);
      _stackEntry = created;
      Overlay.of(context, rootOverlay: true).insert(created);
      return;
    }
    entry.markNeedsBuild();
  }

  Widget _buildStack(BuildContext overlayContext) {
    final media = MediaQuery.of(overlayContext);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + media.padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in _items)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _LicoToastItemView(
                  key: ValueKey<int>(item.id),
                  item: item,
                  onDismissed: () => _dismissItem(item.id),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      _LicoToastHostScope(state: this, child: widget.child);

  @override
  void dispose() {
    final entry = _stackEntry;
    _stackEntry = null;
    if (entry != null && entry.mounted) {
      entry.remove();
    }
    super.dispose();
  }
}

final class _LicoToastHostScope extends InheritedWidget {
  const _LicoToastHostScope({required this.state, required super.child});

  final LicoToastHostState state;

  @override
  bool updateShouldNotify(_LicoToastHostScope oldWidget) =>
      !identical(oldWidget.state, state);
}

final class _LicoToastItem {
  const _LicoToastItem({
    required this.id,
    required this.message,
    required this.kind,
    required this.icon,
    required this.iconColor,
    required this.showDuration,
    this.actionLabel,
    this.onAction,
  });

  final int id;
  final String message;
  final LicoToastKind kind;
  final IconData? icon;
  final Color? iconColor;
  final Duration showDuration;
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// One animated toast in the stack: fade/slide entrance, auto-dismiss timer,
/// reverse exit, then removal. Lifecycle mirrors the proven status-capsule
/// toast this component replaces.
class _LicoToastItemView extends StatefulWidget {
  const _LicoToastItemView({
    super.key,
    required this.item,
    required this.onDismissed,
  });

  final _LicoToastItem item;
  final VoidCallback onDismissed;

  @override
  State<_LicoToastItemView> createState() => _LicoToastItemViewState();
}

class _LicoToastItemViewState extends State<_LicoToastItemView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _autoDismissTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: LicoMotion.medium,
      reverseDuration: LicoMotion.short,
    )..forward();
    _autoDismissTimer = Timer(widget.item.showDuration, _dismiss);
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _autoDismissTimer?.cancel();
    if (!mounted || _dismissing) {
      return;
    }
    _dismissing = true;
    _controller.reverse().whenComplete(widget.onDismissed);
  }

  @override
  Widget build(BuildContext context) {
    final entrance = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: entrance,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(entrance),
        child: LicoToast(
          key: ValueKey<String>('lico-toast-${widget.item.id}'),
          message: widget.item.message,
          kind: widget.item.kind,
          icon: widget.item.icon,
          iconColor: widget.item.iconColor,
          onTap: _dismiss,
          actionLabel: widget.item.actionLabel,
          onAction: widget.item.onAction == null
              ? null
              : () {
                  widget.item.onAction!();
                  _dismiss();
                },
        ),
      ),
    );
  }
}

/// One native-agent activity notice in [LicoToastNoticesSnapshot], with the
/// display name pre-computed by the binding (which owns feature imports).
final class LicoToastAgentNotice {
  const LicoToastAgentNotice({
    required this.id,
    required this.displayName,
    required this.activity,
  });

  /// Stable identity of the conversation target (the target id).
  final String id;

  /// Brand display name of the target (for example "Codex").
  final String displayName;

  final AgentConversationTabActivity activity;
}

/// Snapshot of the chrome notification-notices exposure (frozen contract 4).
///
/// The binding chrome features build this from the chrome projection without
/// changing how notices are produced; [LicoToastNoticesListener] only changes
/// how they surface. Revisions mirror the projection's auto-reveal counters:
/// a higher value signals a fresh arrival since the previous snapshot.
final class LicoToastNoticesSnapshot {
  const LicoToastNoticesSnapshot({
    this.operationNotices = const <ChromeOperationNotificationProjection>[],
    this.agentNotices = const <LicoToastAgentNotice>[],
    this.gatewayNotice,
    this.operationRevision = 0,
    this.gatewayRevision = 0,
  });

  final List<ChromeOperationNotificationProjection> operationNotices;
  final List<LicoToastAgentNotice> agentNotices;
  final ChromeGatewayNotificationProjection? gatewayNotice;
  final int operationRevision;
  final int gatewayRevision;
}

/// Maps the chrome notification-notices exposure to floating toasts,
/// replacing the notification bell popover on desktop layouts.
///
/// Notices present in the first snapshot are the baseline — only arrivals
/// after mounting toast. Operation notices toast when the operation revision
/// advances and their id is new or their content changed; gateway notices
/// toast when the gateway revision advances; agent notices toast when a new
/// (target, activity) pair appears.
class LicoToastNoticesListener extends StatefulWidget {
  const LicoToastNoticesListener({
    super.key,
    required this.notices,
    required this.child,
    this.onActivate,
  });

  /// The chrome notification-notices exposure (frozen contract 4).
  final ValueListenable<LicoToastNoticesSnapshot> notices;

  final Widget child;
  final ValueChanged<ChromeOperationNotificationProjection>? onActivate;

  @override
  State<LicoToastNoticesListener> createState() =>
      _LicoToastNoticesListenerState();
}

class _LicoToastNoticesListenerState extends State<LicoToastNoticesListener> {
  late int _seenOperationRevision;
  late int _seenGatewayRevision;
  late Map<String, ChromeOperationNotificationProjection> _operationNoticesById;
  late Set<String> _agentNoticeKeys;

  @override
  void initState() {
    super.initState();
    _baseline(widget.notices.value);
    widget.notices.addListener(_handleNoticesChanged);
  }

  @override
  void didUpdateWidget(covariant LicoToastNoticesListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.notices, widget.notices)) {
      oldWidget.notices.removeListener(_handleNoticesChanged);
      _baseline(widget.notices.value);
      widget.notices.addListener(_handleNoticesChanged);
    }
  }

  @override
  void dispose() {
    widget.notices.removeListener(_handleNoticesChanged);
    super.dispose();
  }

  void _baseline(LicoToastNoticesSnapshot snapshot) {
    _seenOperationRevision = snapshot.operationRevision;
    _seenGatewayRevision = snapshot.gatewayRevision;
    _operationNoticesById = <String, ChromeOperationNotificationProjection>{
      for (final notice in snapshot.operationNotices) notice.id: notice,
    };
    _agentNoticeKeys = <String>{
      for (final notice in snapshot.agentNotices) _agentKey(notice),
    };
  }

  void _handleNoticesChanged() {
    final snapshot = widget.notices.value;
    // A source that restarted its revisions (for example a fresh session)
    // becomes the new baseline instead of re-toasting every stored notice.
    if (snapshot.operationRevision < _seenOperationRevision ||
        snapshot.gatewayRevision < _seenGatewayRevision) {
      _baseline(snapshot);
      return;
    }
    if (snapshot.operationRevision > _seenOperationRevision) {
      for (final notice in snapshot.operationNotices) {
        if (_operationNoticesById[notice.id] != notice) {
          _toastOperationNotice(notice);
        }
      }
    }
    _seenOperationRevision = snapshot.operationRevision;
    _operationNoticesById = <String, ChromeOperationNotificationProjection>{
      for (final notice in snapshot.operationNotices) notice.id: notice,
    };

    if (snapshot.gatewayRevision > _seenGatewayRevision) {
      final gateway = snapshot.gatewayNotice;
      if (gateway != null) {
        _toastGatewayNotice(gateway);
      }
    }
    _seenGatewayRevision = snapshot.gatewayRevision;

    final currentKeys = <String>{};
    for (final notice in snapshot.agentNotices) {
      final key = _agentKey(notice);
      currentKeys.add(key);
      if (!_agentNoticeKeys.contains(key)) {
        _toastAgentNotice(notice);
      }
    }
    _agentNoticeKeys = currentKeys;
  }

  String _agentKey(LicoToastAgentNotice notice) =>
      '${notice.id}:${notice.activity.name}';

  void _toastOperationNotice(ChromeOperationNotificationProjection notice) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final message = chinese ? notice.messageChinese : notice.messageEnglish;
    if (message.trim().isEmpty) return;
    final actionLabel = notice.completionTarget == null
        ? null
        : (chinese ? '打开原事项' : 'Open original matter');
    final onAction = notice.completionTarget == null
        ? null
        : () => widget.onActivate?.call(notice);
    switch (notice.severity) {
      case PresentationNoticeSeverity.error:
        showLicoToast(
          context,
          message: message,
          kind: LicoToastKind.error,
          actionLabel: actionLabel,
          onAction: onAction,
        );
      case PresentationNoticeSeverity.warning:
        // The legacy bell surfaced warnings with the amber glyph; keep that
        // accent on the unified toast.
        showLicoToast(
          context,
          message: message,
          kind: LicoToastKind.error,
          icon: Icons.warning_amber_rounded,
          iconColor: context.licoColors.warning,
          actionLabel: actionLabel,
          onAction: onAction,
        );
      case PresentationNoticeSeverity.success:
        showLicoToast(
          context,
          message: message,
          kind: LicoToastKind.success,
          actionLabel: actionLabel,
          onAction: onAction,
        );
      case PresentationNoticeSeverity.information:
        showLicoToast(
          context,
          message: message,
          kind: LicoToastKind.info,
          actionLabel: actionLabel,
          onAction: onAction,
        );
    }
  }

  void _toastGatewayNotice(ChromeGatewayNotificationProjection notice) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    switch (notice.kind) {
      case ChromeGatewayNoticeKind.recovering:
        showLicoToast(
          context,
          message: chinese
              ? 'LLM Gateway 正在自动恢复（${notice.recoveryAttempt}/${notice.maxRecoveryAttempts}）…'
              : 'Recovering LLM Gateway '
                    '(${notice.recoveryAttempt}/${notice.maxRecoveryAttempts})…',
          kind: LicoToastKind.info,
        );
      case ChromeGatewayNoticeKind.recoveryFailed:
        showLicoToast(
          context,
          message: chinese
              ? 'LLM Gateway 自动恢复失败，诊断已记录。'
              : 'LLM Gateway recovery failed. Diagnostics recorded.',
          kind: LicoToastKind.error,
          icon: Icons.warning_amber_rounded,
          iconColor: context.licoColors.warning,
        );
    }
  }

  void _toastAgentNotice(LicoToastAgentNotice notice) {
    final strings = LicoStrings.of(context);
    final status = switch (notice.activity) {
      AgentConversationTabActivity.needsApproval =>
        strings.agentTabNeedsApproval,
      AgentConversationTabActivity.workFinished => strings.agentTabWorkFinished,
      AgentConversationTabActivity.none => '',
    };
    if (status.isEmpty) return;
    showLicoToast(
      context,
      message: '${notice.displayName} · $status',
      kind: LicoToastKind.notification,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
