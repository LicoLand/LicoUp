import 'package:presentation_contract/presentation_contract.dart';

sealed class PluginWindowEffect {
  const PluginWindowEffect({this.trace});

  final TraceContext? trace;
}

/// An open request was refused; [code] is a stable machine code such as
/// `plugin_window_not_installed`.
final class PluginWindowOpenRejected extends PluginWindowEffect {
  const PluginWindowOpenRejected(this.pluginId, this.code, {super.trace});

  final String pluginId;
  final String code;
}
