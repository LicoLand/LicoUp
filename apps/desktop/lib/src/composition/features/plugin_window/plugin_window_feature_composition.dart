import 'package:licoup/src/contracts/plugin_window_host_port.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_binding.dart';
import 'package:licoup/src/projections/plugin_window/plugin_window_presentation_source.dart';

/// Plugin window feature wiring over the reserved host port.
///
/// Native WebView adapters do not exist yet, so the root registers
/// [UnsupportedPluginWindowHostPort]: the catalog is empty and any session
/// reports unsupported.
final class PluginWindowFeatureComposition {
  PluginWindowFeatureComposition({
    PluginWindowHostPort? port,
    PluginWindowBinding Function(PluginWindowPresentationSource source)?
    wrapBinding,
  }) : _source = PluginWindowPresentationSource(
         port: port ?? const UnsupportedPluginWindowHostPort(),
       ) {
    binding = (wrapBinding ?? _plainBinding)(_source);
  }

  final PluginWindowPresentationSource _source;
  late final PluginWindowBinding binding;

  Future<void> close() => _source.dispose();

  static PluginWindowBinding _plainBinding(
    PluginWindowPresentationSource source,
  ) =>
      PluginWindowBinding(projection: source, intents: source, effects: source);
}
