import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/agent_hub/agent_hub_effect.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_intent.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';

final class AgentHubBinding {
  const AgentHubBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<AgentHubProjection> projection;
  final IntentSink<AgentHubIntent> intents;
  final EffectSource<AgentHubEffect> effects;
}
