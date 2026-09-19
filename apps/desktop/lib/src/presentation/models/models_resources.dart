import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/models/models_projection.dart';

/// Stable ownership scope for the models feature presentation resources.
const modelsPresentationScope = ResourceScope('models');

/// Identity of the model catalog resource inside [modelsPresentationScope].
const modelsCatalogResource = ResourceKey(
  scope: modelsPresentationScope,
  stableKey: 'catalog',
);

/// Typed field group carrying the model catalog snapshot.
const modelsCatalogFields = ResourceFieldGroup<ModelsProjection>(
  resource: modelsCatalogResource,
  name: 'overview',
);
