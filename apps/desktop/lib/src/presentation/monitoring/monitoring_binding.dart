import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/monitoring/monitoring_effect.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';

final class MonitoringBinding {
  const MonitoringBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<MonitoringProjection> projection;
  final IntentSink<MonitoringIntent> intents;
  final EffectSource<MonitoringEffect> effects;
}
