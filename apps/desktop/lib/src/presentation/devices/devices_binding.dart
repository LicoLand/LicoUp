import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/devices/devices_effect.dart';
import 'package:licoup/src/presentation/devices/devices_intent.dart';
import 'package:licoup/src/presentation/devices/devices_projection.dart';

final class DevicesBinding {
  const DevicesBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<DevicesProjection> projection;
  final IntentSink<DevicesIntent> intents;
  final EffectSource<DevicesEffect> effects;
}
