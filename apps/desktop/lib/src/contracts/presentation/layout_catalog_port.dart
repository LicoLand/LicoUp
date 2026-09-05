import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/layout_variant.dart';

/// Renderer-safe immutable view of the validated Application layout catalog.
abstract interface class LayoutCatalogView {
  Iterable<LayoutProfileId> get profileIds;
  Iterable<LayoutVariantKey> get variantKeys;
  Iterable<LayoutStateNamespace> get stateNamespaces;

  LayoutProfileDescriptor? profile(LayoutProfileId id);
  LayoutVariantCoverage coverage(LayoutVariantKey key);
  bool declaresStateNamespace(LayoutStateNamespace namespace);
}
