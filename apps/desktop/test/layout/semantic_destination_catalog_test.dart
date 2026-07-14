import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('current catalog declares the exact canonical surface products', () {
    final catalog = SemanticDestinationCatalog.current();

    expect(catalog.descriptors, hasLength(ClientSection.values.length));
    expect(catalog.destinationsFor(LayoutRuntimeSurface.desktop), {
      ClientSection.controlPanel,
      ClientSection.agents,
      ClientSection.monitoring,
      ClientSection.mcpPlugins,
      ClientSection.localRuntime,
      ClientSection.mobileRelay,
      ClientSection.settings,
    });
    expect(catalog.destinationsFor(LayoutRuntimeSurface.mobile), {
      ClientSection.agents,
      ClientSection.feed,
      ClientSection.mobileRelay,
      ClientSection.settings,
    });
  });

  test('semantic aliases resolve before surface coverage checks', () {
    final catalog = SemanticDestinationCatalog.current();

    expect(catalog.resolve(ClientSection.skillHub), ClientSection.mcpPlugins);
    expect(
      catalog.supports(ClientSection.skillHub, LayoutRuntimeSurface.desktop),
      isTrue,
    );
    expect(
      catalog.supports(ClientSection.skillHub, LayoutRuntimeSurface.mobile),
      isFalse,
    );
    expect(
      () => catalog
          .destinationsFor(LayoutRuntimeSurface.desktop)
          .add(ClientSection.feed),
      throwsUnsupportedError,
    );
  });

  test('catalog rejects duplicate, incomplete, and cyclic definitions', () {
    final current = SemanticDestinationCatalog.current();
    expect(
      () => SemanticDestinationCatalog([
        ...current.descriptors,
        current.descriptors.first,
      ]),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => SemanticDestinationCatalog(current.descriptors.skip(1)),
      throwsA(isA<FormatException>()),
    );

    final cyclic = current.descriptors.map((descriptor) {
      if (descriptor.destination == ClientSection.mcpPlugins) {
        return SemanticDestinationDescriptor(
          destination: descriptor.destination,
          labelKey: descriptor.labelKey,
          surfaces: descriptor.surfaces,
          aliasOf: ClientSection.skillHub,
        );
      }
      return descriptor;
    });
    expect(
      () => SemanticDestinationCatalog(cyclic),
      throwsA(isA<FormatException>()),
    );
  });
}
