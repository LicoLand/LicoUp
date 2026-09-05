import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/search/search_effect.dart';
import 'package:licoup/src/presentation/search/search_intent.dart';
import 'package:licoup/src/presentation/search/search_projection.dart';

final class SearchBinding {
  const SearchBinding({
    required this.projection,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<SearchProjection> projection;
  final IntentSink<SearchIntent> intents;
  final EffectSource<SearchEffect> effects;
}
