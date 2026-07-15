import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/preview/studio_desktop_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/studio_desktop.dart';

import './studio_desktop_test_harness.dart';

void main() {
  test('bundle exposes the exact immutable Studio desktop contract', () {
    final bundle = studioDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('studio'));
    expect(bundle.profile.label.resolve('en'), 'Native');
    expect(bundle.profile.description.resolve('zh'), contains('默认'));
    expect(bundle.profile.styleIdentity, 'dense-docked-studio');
    expect(bundle.profile.isDefault, isTrue);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.assetNamespace, 'layout-profiles/studio/desktop');
    expect(bundle.restorationNamespace, 'studio.desktop');
    expect(bundle.components.styleIdentity, 'dense-docked-studio');
    expect(bundle.tokens.density, lessThan(1));
    expect(bundle.tokens.cardRadius, lessThanOrEqualTo(2));
    expect(bundle.tokens.elevation, 0);

    expect(bundle.variants.keys.toSet(), <LayoutViewportClass>{
      LayoutViewportClass.medium,
      LayoutViewportClass.expanded,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        studioDesktopExpectedDestinations,
      );
      expect(
        () => variant.destinationBuilders.remove(ClientSection.settings),
        throwsUnsupportedError,
      );
    }
    expect(
      () => bundle.variants.remove(LayoutViewportClass.medium),
      throwsUnsupportedError,
    );
  });

  test('state namespaces are profile-qualified and business-scoped', () {
    final namespaces = studioDesktopBundle.stateNamespaces;

    expect(namespaces, hasLength(5));
    expect(namespaces.map((value) => value.destination).toSet(), {
      ClientSection.agents,
      ClientSection.settings,
    });
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('studio'));
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
    expect(() => namespaces.clear(), throwsUnsupportedError);
  });

  test('coverage is exact for medium and expanded variants', () {
    final coverage = studioDesktopBundle.coverage.toList(growable: false);

    expect(coverage, hasLength(2));
    for (final entry in coverage) {
      expect(entry.key.profileId, LayoutProfileId.parse('studio'));
      expect(entry.key.surface, LayoutRuntimeSurface.desktop);
      expect(entry.destinations, studioDesktopExpectedDestinations);
    }
  });

  test('preview metadata is deterministic and structurally Studio-owned', () {
    expect(studioDesktopPreviewMetadata.styleIdentity, 'dense-docked-studio');
    expect(studioDesktopPreviewMetadata.structuralLandmarks, <String>[
      'context-rail',
      'workspace-bar',
      'edge-editor',
      'inspector-dock',
    ]);
  });

  testWidgets('actions and content port reject destinations outside contract', (
    tester,
  ) async {
    final actions = StudioActionRecorder();
    final content = StudioRecordingContentPort(actions);

    expect(
      () => actions.selectDestination(ClientSection.feed),
      throwsFormatException,
    );
    expect(
      () => actions.invokeContentAction(ClientSection.skillHub, 'primary'),
      throwsFormatException,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            expect(
              () => content.buildDestination(context, ClientSection.feed),
              throwsFormatException,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(content.buildCalls, isEmpty);
  });

  for (final destination in studioDesktopExpectedDestinations) {
    testWidgets('content adapter is exact for ${destination.name}', (
      tester,
    ) async {
      const size = Size(900, 620);
      configureStudioTestView(tester, size);
      final actions = StudioActionRecorder();
      final content = StudioRecordingContentPort(actions);

      await tester.pumpWidget(
        StudioDesktopTestHarness(
          environment: studioDesktopEnvironment(
            width: size.width,
            height: size.height,
          ),
          activeDestination: destination,
          content: content,
          actions: actions,
        ),
      );
      await tester.pump();

      expect(content.buildCalls, <ClientSection>[destination]);
      expect(
        find.byKey(ValueKey<String>('studio-fake-content-${destination.name}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
