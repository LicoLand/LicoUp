import 'package:licoup/src/presentation/layout/layout_catalog.dart';
import 'package:licoup/src/presentation/layout/semantic_destination_catalog.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';

LayoutCatalog createBuiltInLayoutCatalog() => LayoutCatalog(
  revision: 1,
  profiles: BuiltInLayoutSpec.profiles,
  variants: BuiltInLayoutSpec.variants,
  destinationCatalog: SemanticDestinationCatalog.current(),
  stateNamespaces: BuiltInLayoutSpec.stateNamespaces,
);
