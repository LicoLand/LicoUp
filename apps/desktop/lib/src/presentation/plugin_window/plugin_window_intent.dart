import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/plugin_window_host_models.dart';

sealed class PluginWindowIntent {
  const PluginWindowIntent(this.pluginId, {this.trace});

  final String pluginId;
  final TraceContext? trace;
}

/// Opens the window of an installed plugin; a window already open stays
/// as it is.
final class OpenPluginWindow extends PluginWindowIntent {
  const OpenPluginWindow(super.pluginId, {super.trace});
}

final class ReloadPluginWindow extends PluginWindowIntent {
  const ReloadPluginWindow(super.pluginId, {super.trace});
}

final class ClosePluginWindow extends PluginWindowIntent {
  const ClosePluginWindow(super.pluginId, {super.trace});
}

final class DecidePluginWindowPermission extends PluginWindowIntent {
  const DecidePluginWindowPermission(
    super.pluginId,
    this.decision, {
    super.trace,
  });

  final PluginPermissionDecision decision;
}
