import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';

final class AgentsBinding {
  const AgentsBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<AgentsProjection> projection;
  final IntentSink<AgentsIntent> intents;
  final EffectSource<AgentsEffect> effects;
}
