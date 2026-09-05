import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/settings/settings_effect.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

final class SettingsBinding {
  const SettingsBinding({
    required this.projection,
    required this.resourceUsage,
    required this.autostart,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<SettingsProjection> projection;
  final ProjectionSource<SettingsResourceUsageProjection> resourceUsage;
  final ProjectionSource<SettingsAutostartProjection> autostart;
  final IntentSink<SettingsIntent> intents;
  final EffectSource<SettingsEffect> effects;
}
