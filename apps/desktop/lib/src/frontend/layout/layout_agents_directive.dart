import 'package:flutter/widgets.dart';

/// How the shared Agents workspace renders its conversation sidebar.
enum LayoutAgentsSidebarMode {
  /// The workspace's own conversation list beside the detail.
  list,

  /// A pinned avatar column beside the detail; the full list opens from the
  /// conversation header's switcher.
  avatarColumn,

  /// Only the avatar column, under an expand control; the shell has
  /// collapsed the sidebar to a rail.
  avatarRail,
}

/// Opt-in, presentation-only directives a layout shell installs above the
/// shared Agents workspace. Shells that never install the scope keep the
/// workspace's built-in behavior exactly (Dashboard never provides one).
final class LayoutAgentsDirective {
  const LayoutAgentsDirective({
    this.sidebarCollapsed,
    this.sidebarMode = LayoutAgentsSidebarMode.list,
    this.selectLocalGroupWhenIdle = false,
    this.switcherOpen = false,
    this.onToggleSwitcher,
    this.onCollapseSidebar,
    this.onExpandSidebar,
  });

  /// When non-null, overrides the workspace's own sidebar collapse state so
  /// the shell owns whether the conversation list is visible.
  final bool? sidebarCollapsed;

  final LayoutAgentsSidebarMode sidebarMode;

  /// When true, the workspace selects the pinned Local group conversation
  /// once whenever it settles with no conversation selected at all, so the
  /// shell's conversation region always opens on the Local group chat.
  final bool selectLocalGroupWhenIdle;

  /// Whether the header switcher's full conversation list is open over the
  /// detail (avatar modes only).
  final bool switcherOpen;

  /// When non-null, the conversation headers carry a switcher control that
  /// invokes this toggle; Escape and outside clicks invoke it to close.
  final VoidCallback? onToggleSwitcher;

  /// When non-null, the conversation headers carry a control that collapses
  /// the shell's sidebar to its rail.
  final VoidCallback? onCollapseSidebar;

  /// When non-null, the rail carries an expand control, and choosing a
  /// conversation from the rail expands the sidebar through it.
  final VoidCallback? onExpandSidebar;

  @override
  bool operator ==(Object other) =>
      other is LayoutAgentsDirective &&
      other.sidebarCollapsed == sidebarCollapsed &&
      other.sidebarMode == sidebarMode &&
      other.selectLocalGroupWhenIdle == selectLocalGroupWhenIdle &&
      other.switcherOpen == switcherOpen &&
      other.onToggleSwitcher == onToggleSwitcher &&
      other.onCollapseSidebar == onCollapseSidebar &&
      other.onExpandSidebar == onExpandSidebar;

  @override
  int get hashCode => Object.hash(
    sidebarCollapsed,
    sidebarMode,
    selectLocalGroupWhenIdle,
    switcherOpen,
    onToggleSwitcher,
    onCollapseSidebar,
    onExpandSidebar,
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
