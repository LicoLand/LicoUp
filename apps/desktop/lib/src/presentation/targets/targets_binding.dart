import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/targets/targets_effect.dart';
import 'package:licoup/src/presentation/targets/targets_intent.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';

final class TargetsBinding {
  const TargetsBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<TargetsProjection> projection;
  final IntentSink<TargetsIntent> intents;
  final EffectSource<TargetsEffect> effects;
}
