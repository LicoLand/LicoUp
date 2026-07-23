import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_tokens.dart';

import './classic_mobile_test_harness.dart';

void main() {
  test('exports the exact immutable Classic mobile bundle', () {
    final bundle = classicMobileBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('classic'));
    expect(bundle.profile.label.resolve('en'), 'Dashboard');
    expect(bundle.profile.description.resolve('zh'), contains('控制台'));
    expect(bundle.profile.styleIdentity, classicMobileStyleIdentity);
    expect(bundle.profile.isDefault, isFalse);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.mobile);
    expect(bundle.assetNamespace, 'layout-profiles/classic/mobile');
    expect(bundle.restorationNamespace, classicMobileRestorationPrefix);
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.tokens.cardRadius, 24);
    expect(bundle.tokens.elevation, 1);
    expect(bundle.variants.keys.toSet(), {
      LayoutViewportClass.compact,
      LayoutViewportClass.medium,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        classicMobileDestinations,
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
    final namespaces = classicMobileBundle.stateNamespaces;
    expect(namespaces, hasLength(4));
    expect(namespaces.map((value) => value.destination).toSet(), {
      ClientSection.agents,
      ClientSection.settings,
    });
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('classic'));
      expect(namespace.surface, LayoutRuntimeSurface.mobile);
    }
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
  });

  test('coverage is exact for both declared mobile viewports', () {
    final coverage = classicMobileBundle.coverage.toList(growable: false);

    expect(coverage, hasLength(2));
    expect(coverage.map((entry) => entry.key.viewport).toSet(), {
      LayoutViewportClass.compact,
      LayoutViewportClass.medium,
    });
    for (final entry in coverage) {
      expect(entry.key.profileId, LayoutProfileId.parse('classic'));
      expect(entry.key.surface, LayoutRuntimeSurface.mobile);
      expect(entry.destinations, classicMobileDestinations);
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
    final environment = classicMobileEnvironment();
    final harness = ClassicMobileHarness();
    final compact = classicMobileBundle.variants[LayoutViewportClass.compact]!;

    for (final entry in compact.destinationBuilders.entries) {
      final mismatch = classicMobileDestinations.firstWhere(
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
    for (final destination in classicMobileDestinations) {
      final harness = ClassicMobileHarness(activeDestination: destination);
      await pumpClassicMobileHarness(
        tester,
        harness: harness,
        environment: classicMobileEnvironment(),
      );

      expect(harness.content.builtDestinations, contains(destination));
      await tester.tap(
        find.byKey(
          ValueKey<String>('classic-mobile-fake-action-${destination.name}'),
        ),
      );
      await tester.pump();
      expect(harness.content.invokedActions, [destination]);
    }
  });
}
