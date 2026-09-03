import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

final class ShellBinding {
  const ShellBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<ShellProjection> projection;
  final IntentSink<ShellIntent> intents;
  final EffectSource<ShellEffect> effects;
}
