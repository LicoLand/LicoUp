import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

final class ShellBinding {
  const ShellBinding({
    required this.appearance,
    required this.locale,
    required this.layout,
    required this.environment,
    required this.navigation,
    required this.status,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<AppearanceProjection> appearance;
  final ProjectionSource<LocaleProjection> locale;
  final ProjectionSource<LayoutProjection> layout;
  final ProjectionSource<EnvironmentProjection> environment;
  final ProjectionSource<NavigationProjection> navigation;
  final ProjectionSource<StatusProjection> status;
  final IntentSink<ShellIntent> intents;
  final EffectSource<ShellEffect> effects;
}
