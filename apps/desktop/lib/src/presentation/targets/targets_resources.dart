import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/targets/targets_projection.dart';

/// Stable ownership scope for the targets feature presentation resources.
const targetsPresentationScope = ResourceScope('targets');

/// Identity of the target catalog resource inside [targetsPresentationScope].
const targetsCatalogResource = ResourceKey(
  scope: targetsPresentationScope,
  stableKey: 'catalog',
);

/// Typed field group carrying the target catalog snapshot.
const targetsCatalogFields = ResourceFieldGroup<TargetsProjection>(
  resource: targetsCatalogResource,
  name: 'overview',
);
