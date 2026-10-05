import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projected_presentation_source.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/models/models_resources.dart';

/// The model catalog resource adapter over the models projection owner.
///
/// The source/subscription lifecycle — epoch identity, monotonic versions, one
/// consistency group per accepted change, subscribe-before-read opening and the
/// observer ref count — belongs to [ProjectedPresentationSource]. This type
/// declares only the resource identity this feature owns.
final class ModelsPresentationSource
    extends ProjectedPresentationSource<ModelsProjection, ModelsProjection> {
  ModelsPresentationSource({required super.projection})
    : super(fieldGroup: modelsCatalogFields, epochKey: 'models-catalog');
}
