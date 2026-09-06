import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';

final class MobileRelayBinding {
  const MobileRelayBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<MobileRelayProjection> projection;
  final IntentSink<MobileRelayIntent> intents;
  final EffectSource<MobileRelayEffect> effects;
}
