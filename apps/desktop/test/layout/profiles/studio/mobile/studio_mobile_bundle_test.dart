import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_bundle.dart';

import './studio_mobile_test_harness.dart';

void main() {
  test('exports the exact immutable Studio mobile bundle product', () {
    final bundle = studioMobileBundle;

    expect(bundle.profile.id, LayoutProfileId.studio);
    expect(bundle.profile.labelKey, 'layout.profile.studio.label');
    expect(bundle.profile.descriptionKey, 'layout.profile.studio.description');
    expect(bundle.profile.styleIdentity, 'dense-docked-studio');
    expect(bundle.profile.isDefault, isFalse);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.mobile);
    expect(bundle.assetNamespace, 'layout-profiles/studio/mobile');
    expect(bundle.restorationNamespace, 'studio.mobile');
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.variants.keys.toSet(), {
      LayoutViewportClass.compact,
      LayoutViewportClass.medium,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        studioMobileDestinations,
      );
    }

    expect(() => bundle.variants.clear(), throwsUnsupportedError);
    expect(
      () => bundle.variants.values.first.destinationBuilders.clear(),
      throwsUnsupportedError,
    );
    expect(() => bundle.stateNamespaces.clear(), throwsUnsupportedError);
  });

  test('declares one isolated state namespace for every destination', () {
    final byDestination = {
      for (final namespace in studioMobileBundle.stateNamespaces)
        namespace.destination: namespace,
    };

    expect(byDestination.keys, studioMobileDestinations);
    expect(
      byDestination[ClientSection.agents]!.surfaceId,
      'conversation-scroll',
    );
    expect(byDestination[ClientSection.feed]!.surfaceId, 'feed-scroll');
    expect(byDestination[ClientSection.mobileRelay]!.surfaceId, 'pairing-flow');
    expect(byDestination[ClientSection.settings]!.surfaceId, 'settings-scroll');
    for (final namespace in byDestination.values) {
      expect(namespace.profileId, LayoutProfileId.studio);
      expect(namespace.surface, LayoutRuntimeSurface.mobile);
    }
  });

  testWidgets('adapters fail closed on destination mismatch', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final environment = studioMobileEnvironment();
    final harness = StudioMobileHarness();
    final compact = studioMobileBundle.variants[LayoutViewportClass.compact]!;

    for (final entry in compact.destinationBuilders.entries) {
      final mismatch = studioMobileDestinations.firstWhere(
        (destination) => destination != entry.key,
      );
      expect(
        () => entry.value(
          context,
          harness.destinationData(environment, mismatch),
        ),
        throwsA(isA<FormatException>()),
        reason: '${entry.key.name} must reject ${mismatch.name}',
      );
    }
  });

  testWidgets('every adapter forwards content and parent-owned actions', (
    tester,
  ) async {
    for (final destination in studioMobileDestinations) {
      final harness = StudioMobileHarness(activeDestination: destination);
      await pumpStudioMobileHarness(
        tester,
        harness: harness,
        environment: studioMobileEnvironment(),
      );

      expect(harness.content.builtDestinations, contains(destination));
      await tester.tap(
        find.byKey(ValueKey('studio-fake-action-${destination.name}')),
      );
      await tester.pump();
      expect(harness.content.invokedActions, [destination]);
    }
  });
}
