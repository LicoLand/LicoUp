import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projected_presentation_source.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';
import 'package:licoup/src/presentation/targets/targets_resources.dart';

/// The target catalog resource adapter over the targets projection owner.
///
/// The source/subscription lifecycle — epoch identity, monotonic versions, one
/// consistency group per accepted change, subscribe-before-read opening and the
/// observer ref count — belongs to [ProjectedPresentationSource]. This type
/// declares only the resource identity this feature owns.
final class TargetsPresentationSource
    extends ProjectedPresentationSource<TargetsProjection, TargetsProjection> {
  TargetsPresentationSource({required super.projection})
    : super(fieldGroup: targetsCatalogFields, epochKey: 'targets-catalog');
}
