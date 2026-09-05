import 'package:flutter/widgets.dart';

/// Renderer-local environment value injected by composition. Widgets may use
/// it for display formatting without reading process environment directly.
final class WorkspaceHomeDirectoryScope extends InheritedWidget {
  const WorkspaceHomeDirectoryScope({
    super.key,
    required this.path,
    required super.child,
  });

  final String path;

  static String maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WorkspaceHomeDirectoryScope>()
          ?.path ??
      '';

  @override
  bool updateShouldNotify(WorkspaceHomeDirectoryScope oldWidget) =>
      oldWidget.path != path;
}
