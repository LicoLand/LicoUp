import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/classic_desktop.dart';

import './classic_desktop_test_harness.dart';

void main() {
  test('exports the exact immutable Classic desktop bundle', () {
    final bundle = classicDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('classic'));
    expect(bundle.profile.label.resolve('en'), 'Dashboard');
    expect(bundle.profile.description.resolve('zh'), contains('控制台'));
    expect(bundle.profile.styleIdentity, 'spacious-card-classic');
    expect(bundle.profile.isDefault, isFalse);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.assetNamespace, 'layout-profiles/classic/desktop');
    expect(bundle.restorationNamespace, 'classic.desktop');
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.tokens.density, 1);
    expect(bundle.tokens.cardRadius, 22);
    expect(bundle.tokens.elevation, 2);
    expect(bundle.variants.keys.toSet(), {
      LayoutViewportClass.medium,
      LayoutViewportClass.expanded,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        classicDesktopExpectedDestinations,
      );
    }

    expect(() => bundle.variants.clear(), throwsUnsupportedError);
    expect(
      () => bundle.variants.values.first.destinationBuilders.clear(),
      throwsUnsupportedError,
    );
    expect(() => bundle.stateNamespaces.clear(), throwsUnsupportedError);
  });

  test('declares profile-qualified business presentation-state channels', () {
    final namespaces = classicDesktopBundle.stateNamespaces;

    expect(namespaces, hasLength(5));
    expect(namespaces.map((value) => value.destination).toSet(), {
      ClientSection.agents,
      ClientSection.settings,
    });
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('classic'));
      expect(namespace.surface, LayoutRuntimeSurface.desktop);
    }
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
  });

  test('coverage is exact for both declared desktop viewports', () {
    final coverage = classicDesktopBundle.coverage.toList(growable: false);

    expect(coverage, hasLength(2));
    expect(coverage.map((entry) => entry.key.viewport).toSet(), {
      LayoutViewportClass.medium,
      LayoutViewportClass.expanded,
    });
    for (final entry in coverage) {
      expect(entry.key.profileId, LayoutProfileId.parse('classic'));
      expect(entry.key.surface, LayoutRuntimeSurface.desktop);
      expect(entry.destinations, classicDesktopExpectedDestinations);
    }
  });

  testWidgets('every destination adapter fails closed on mismatch', (
    tester,
  ) async {
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
    final environment = classicDesktopEnvironment(width: 900, height: 620);
    final actions = ClassicDesktopActionRecorder();
    final content = ClassicDesktopRecordingContentPort(actions);
    final scopedState = buildClassicDesktopScopedStateForTest();
    final variant = classicDesktopBundle.variants[LayoutViewportClass.medium]!;
    for (final entry in variant.destinationBuilders.entries) {
      final mismatch = classicDesktopExpectedDestinations.firstWhere(
        (destination) => destination != entry.key,
      );
      expect(
        () => entry.value(
          context,
          buildClassicDesktopDestinationDataForTest(
            environment: environment,
            destination: mismatch,
            content: content,
            state: scopedState,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  for (final destination in classicDesktopExpectedDestinations) {
    testWidgets('forwards ${destination.name} through the content port', (
      tester,
    ) async {
      const size = Size(900, 620);
      configureClassicDesktopTestView(tester, size);
      final actions = ClassicDesktopActionRecorder();
      final content = ClassicDesktopRecordingContentPort(actions);

      await tester.pumpWidget(
        ClassicDesktopTestHarness(
          environment: classicDesktopEnvironment(
            width: size.width,
            height: size.height,
          ),
          activeDestination: destination,
          content: content,
          actions: actions,
        ),
      );
      await tester.pump();

      expect(content.buildCalls, [destination]);
      expect(
        find.byKey(
          ValueKey<String>('classic-fake-content-${destination.name}'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
