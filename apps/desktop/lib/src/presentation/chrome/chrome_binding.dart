import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/chrome/chrome_effect.dart';
import 'package:licoup/src/presentation/chrome/chrome_intent.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';

final class ChromeBinding {
  const ChromeBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<ChromeProjection> projection;
  final IntentSink<ChromeIntent> intents;
  final EffectSource<ChromeEffect> effects;
}
