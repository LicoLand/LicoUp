import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/plugin_management/plugin_management_effect.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';

final class PluginManagementBinding {
  const PluginManagementBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<PluginManagementProjection> projection;
  final IntentSink<PluginManagementIntent> intents;
  final EffectSource<PluginManagementEffect> effects;
}
