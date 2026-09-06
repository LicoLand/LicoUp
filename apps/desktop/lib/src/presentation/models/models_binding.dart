import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/models/models_effect.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';

final class ModelsBinding {
  const ModelsBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<ModelsProjection> projection;
  final IntentSink<ModelsIntent> intents;
  final EffectSource<ModelsEffect> effects;
}
