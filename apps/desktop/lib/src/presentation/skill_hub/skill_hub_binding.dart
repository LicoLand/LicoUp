import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/skill_hub/skill_hub_effect.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';

final class SkillHubBinding {
  const SkillHubBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<SkillHubProjection> projection;
  final IntentSink<SkillHubIntent> intents;
  final EffectSource<SkillHubEffect> effects;
}
