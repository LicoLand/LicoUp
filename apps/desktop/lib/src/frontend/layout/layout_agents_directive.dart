import 'package:flutter/widgets.dart';

/// Opt-in, presentation-only directives a layout shell installs above the
/// shared Agents workspace. Shells that never install the scope keep the
/// workspace's built-in behavior exactly (Dashboard never provides one).
final class LayoutAgentsDirective {
  const LayoutAgentsDirective({
    this.sidebarCollapsed,
    this.selectLocalGroupWhenIdle = false,
    this.historyListOpen = false,
    this.onToggleHistoryList,
  });

  /// When non-null, overrides the workspace's own sidebar collapse state so
  /// the shell owns whether the conversation list is visible.
  final bool? sidebarCollapsed;

  /// When true, the workspace selects the pinned Local group conversation
  /// once whenever it settles with no conversation selected at all, so the
  /// shell's conversation region always opens on the Local group chat.
  final bool selectLocalGroupWhenIdle;

  /// Whether the shell-hosted history list is currently open; the
  /// conversation header's overflow menu reflects this on its 历史对话 entry.
  final bool historyListOpen;

  /// When non-null, the conversation header's overflow menu gains a 历史对话
  /// entry that invokes this toggle.
  final VoidCallback? onToggleHistoryList;

  @override
  bool operator ==(Object other) =>
      other is LayoutAgentsDirective &&
      other.sidebarCollapsed == sidebarCollapsed &&
      other.selectLocalGroupWhenIdle == selectLocalGroupWhenIdle &&
      other.historyListOpen == historyListOpen &&
      other.onToggleHistoryList == onToggleHistoryList;

  @override
  int get hashCode => Object.hash(
    sidebarCollapsed,
    selectLocalGroupWhenIdle,
    historyListOpen,
    onToggleHistoryList,
  );
}

/// Provides the active [LayoutAgentsDirective] to the workspace and the
/// conversation headers without exposing a profile identity.
final class LayoutAgentsDirectiveScope extends InheritedWidget {
  const LayoutAgentsDirectiveScope({
    super.key,
    required this.directive,
    required super.child,
  });

  final LayoutAgentsDirective directive;

  static LayoutAgentsDirective? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LayoutAgentsDirectiveScope>()
      ?.directive;

  @override
  bool updateShouldNotify(LayoutAgentsDirectiveScope oldWidget) =>
      oldWidget.directive != directive;
}
