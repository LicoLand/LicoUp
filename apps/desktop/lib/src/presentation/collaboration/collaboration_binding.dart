import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/collaboration/collaboration_effect.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_intent.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';

final class CollaborationBinding {
  const CollaborationBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<CollaborationProjection> projection;
  final IntentSink<CollaborationIntent> intents;
  final EffectSource<CollaborationEffect> effects;
}
