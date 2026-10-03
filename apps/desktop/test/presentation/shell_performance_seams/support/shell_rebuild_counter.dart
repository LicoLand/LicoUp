import 'package:flutter/widgets.dart';

/// Counts the widget rebuilds one interaction caused, by widget type.
///
/// The counter reads the framework's own debug hook for dirty widget builds,
/// so it observes the real rendering tree: a widget that starts listening to
/// every projection and rebuilding on any of them is counted here even though
/// no production seam was told about it.
final class ShellRebuildCounter {
  final Map<String, int> byWidget = <String, int>{};
  bool _installed = false;

  int get total => byWidget.values.fold(0, (sum, value) => sum + value);

  int of(String widgetType) => byWidget[widgetType] ?? 0;

  /// Counts widgets whose type contains [fragment].
  int matching(String fragment) => byWidget.entries
      .where((entry) => entry.key.contains(fragment))
      .fold(0, (sum, entry) => sum + entry.value);

  void install() {
    debugOnRebuildDirtyWidget = _count;
    _installed = true;
  }

  void clear() => byWidget.clear();

  void remove() {
    if (!_installed) return;
    debugOnRebuildDirtyWidget = null;
    _installed = false;
  }

  void _count(Element element, bool builtOnce) {
    final type = element.widget.runtimeType.toString();
    byWidget.update(type, (count) => count + 1, ifAbsent: () => 1);
  }
}
