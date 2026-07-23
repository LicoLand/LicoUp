import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_bundle.dart';

import './bubble_mobile_test_harness.dart';

void main() {
  test('exports the exact immutable Bubble mobile bundle product', () {
    final bundle = bubbleMobileBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('bubble'));
    expect(bundle.profile.label.resolve('en'), 'Bubble');
    expect(bundle.profile.description.resolve('zh'), contains('胶囊'));
    expect(bundle.profile.styleIdentity, 'dense-docked-bubble');
    expect(bundle.profile.isDefault, isFalse);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.mobile);
    expect(bundle.assetNamespace, 'layout-profiles/bubble/mobile');
    expect(bundle.restorationNamespace, 'bubble.mobile');
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.variants.keys.toSet(), {
      LayoutViewportClass.compact,
      LayoutViewportClass.medium,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        bubbleMobileDestinations,
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
    final namespaces = bubbleMobileBundle.stateNamespaces;
    expect(namespaces, hasLength(4));
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
      expect(namespace.profileId, LayoutProfileId.parse('bubble'));
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
    final environment = bubbleMobileEnvironment();
    final harness = BubbleMobileHarness();
    final compact = bubbleMobileBundle.variants[LayoutViewportClass.compact]!;

    for (final entry in compact.destinationBuilders.entries) {
      final mismatch = bubbleMobileDestinations.firstWhere(
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
    for (final destination in bubbleMobileDestinations) {
      final harness = BubbleMobileHarness(activeDestination: destination);
      await pumpBubbleMobileHarness(
        tester,
        harness: harness,
        environment: bubbleMobileEnvironment(),
      );

      expect(harness.content.builtDestinations, contains(destination));
      await tester.tap(
        find.byKey(ValueKey('bubble-fake-action-${destination.name}')),
      );
      await tester.pump();
      expect(harness.content.invokedActions, [destination]);
    }
  });
}
