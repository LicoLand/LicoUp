import 'package:licoup/src/presentation/layout/semantic_destination_catalog.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('current catalog declares the exact canonical surface products', () {
    final catalog = SemanticDestinationCatalog.current();

    expect(catalog.descriptors, hasLength(ClientSection.values.length));
    expect(catalog.destinationsFor(LayoutRuntimeSurface.desktop), {
      ClientSection.agents,
      ClientSection.monitoring,
      ClientSection.skillHub,
      ClientSection.pluginManagement,
      ClientSection.mobileRelay,
      ClientSection.models,
      ClientSection.settings,
      ClientSection.agentHub,
    });
    expect(catalog.destinationsFor(LayoutRuntimeSurface.mobile), {
      ClientSection.agents,
      ClientSection.mobileRelay,
      ClientSection.settings,
    });
  });

  test('canonical destinations expose immutable surface coverage', () {
    final catalog = SemanticDestinationCatalog.current();

    expect(catalog.resolve(ClientSection.skillHub), ClientSection.skillHub);
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
          .add(ClientSection.agents),
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
      if (descriptor.destination == ClientSection.agents) {
        return SemanticDestinationDescriptor(
          destination: descriptor.destination,
          labelKey: descriptor.labelKey,
          surfaces: descriptor.surfaces,
          aliasOf: ClientSection.settings,
        );
      }
      if (descriptor.destination == ClientSection.settings) {
        return SemanticDestinationDescriptor(
          destination: descriptor.destination,
          labelKey: descriptor.labelKey,
          surfaces: descriptor.surfaces,
          aliasOf: ClientSection.agents,
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
