import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_bundle.dart';

import './studio_mobile_test_harness.dart';

void main() {
  test('exports the exact immutable Studio mobile bundle product', () {
    final bundle = studioMobileBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('studio'));
    expect(bundle.profile.label.resolve('en'), 'Native');
    expect(bundle.profile.description.resolve('zh'), contains('默认'));
    expect(bundle.profile.styleIdentity, 'dense-docked-studio');
    expect(bundle.profile.isDefault, isTrue);
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

  test('declares isolated business presentation-state channels', () {
    final namespaces = studioMobileBundle.stateNamespaces;
    expect(namespaces, hasLength(5));
    expect(namespaces.map((value) => value.destination).toSet(), {
      ClientSection.agents,
      ClientSection.settings,
    });
    expect(
      namespaces
          .where((value) => value.destination == ClientSection.agents)
          .map((value) => value.surfaceId)
          .toSet(),
      {
        LayoutStateChannels.agentsHistory.id,
        LayoutStateChannels.agentsSidebar.id,
        LayoutStateChannels.agentsDestination.id,
      },
    );
    expect(
      namespaces
          .where((value) => value.destination == ClientSection.settings)
          .map((value) => value.surfaceId)
          .toSet(),
      {
        LayoutStateChannels.settingsScroll.id,
        LayoutStateChannels.settingsSection.id,
      },
    );
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('studio'));
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
