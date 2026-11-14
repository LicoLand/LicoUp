import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/plugin_window/plugin_window_effect.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_intent.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_projection.dart';

final class PluginWindowBinding {
  const PluginWindowBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<PluginWindowProjection> projection;
  final IntentSink<PluginWindowIntent> intents;
  final EffectSource<PluginWindowEffect> effects;
}
