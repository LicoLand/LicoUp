import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';

/// Chrome-features stand-in for profile shell tests: feature surfaces are
/// probe widgets, the observable state is plain notifiers, and every call is
/// recorded, so shells are exercised without feature code.
final class FixtureLayoutChromeFeatures implements LayoutChromeFeatures {
  FixtureLayoutChromeFeatures({
    LayoutCollaborationAppState collaboration =
        const LayoutCollaborationAppState(),
    List<LayoutPluginWindowSummary> plugins = const [],
  }) : collaborationState = ValueNotifier(collaboration),
       pluginState = ValueNotifier(plugins);

  final ValueNotifier<LayoutCollaborationAppState> collaborationState;
  final ValueNotifier<List<LayoutPluginWindowSummary>> pluginState;
  final ValueNotifier<LicoToastNoticesSnapshot> _notices = ValueNotifier(
    const LicoToastNoticesSnapshot(),
  );

  final List<String> openedPlugins = [];
  final List<String> closedPlugins = [];
  int collaborationBuilds = 0;
  int quickSwitcherOpens = 0;
  List<LayoutQuickSwitcherApp> quickSwitcherApps = const [];
  ValueChanged<String>? quickSwitcherOnOpenApp;

  @override
  ValueListenable<LicoToastNoticesSnapshot> get notificationNotices => _notices;

  @override
  ValueNotifier<bool>? get auxChromePanelOpen => null;

  @override
  void activateOperationNotice(notice) {}

  @override
  ValueListenable<LayoutCollaborationAppState> get collaborationApp =>
      collaborationState;

  @override
  Widget buildCollaborationApp(BuildContext context) {
    collaborationBuilds += 1;
    return const ColoredBox(
      key: Key('fixture-collaboration-app'),
      color: Colors.transparent,
      child: Center(child: Text('collaboration')),
    );
  }

  @override
  ValueListenable<List<LayoutPluginWindowSummary>> get pluginWindows =>
      pluginState;

  @override
  void openPluginWindow(String pluginId) {
    openedPlugins.add(pluginId);
    _setOpen(pluginId, true);
  }

  @override
  void closePluginWindow(String pluginId) {
    closedPlugins.add(pluginId);
    _setOpen(pluginId, false);
  }

  void _setOpen(String pluginId, bool open) {
    pluginState.value = [
      for (final plugin in pluginState.value)
        plugin.id == pluginId
            ? LayoutPluginWindowSummary(
                id: plugin.id,
                name: plugin.name,
                official: plugin.official,
                open: open,
              )
            : plugin,
    ];
  }

  @override
  Widget buildPluginWindow(BuildContext context, String pluginId) => ColoredBox(
    key: ValueKey<String>('fixture-plugin-window-$pluginId'),
    color: Colors.transparent,
    child: Center(child: Text('plugin $pluginId')),
  );

  @override
  Widget buildPluginWindowActions(
    BuildContext context,
    String pluginId, {
    required VoidCallback onOpenPermissionSettings,
    required VoidCallback onClose,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton(
        key: ValueKey<String>('fixture-plugin-permissions-$pluginId'),
        onPressed: onOpenPermissionSettings,
        child: const Text('permissions'),
      ),
      TextButton(
        key: ValueKey<String>('fixture-plugin-close-$pluginId'),
        onPressed: onClose,
        child: const Text('close'),
      ),
    ],
  );

  @override
  Future<void> openQuickSwitcher(
    BuildContext context, {
    required List<LayoutQuickSwitcherApp> apps,
    required ValueChanged<String> onOpenApp,
  }) async {
    quickSwitcherOpens += 1;
    quickSwitcherApps = apps;
    quickSwitcherOnOpenApp = onOpenApp;
  }
}
