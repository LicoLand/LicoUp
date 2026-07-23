import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/preview/bubble_desktop_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/bubble_desktop.dart';

import './bubble_desktop_test_harness.dart';

void main() {
  test('bundle exposes the exact immutable Bubble desktop contract', () {
    final bundle = bubbleDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('bubble'));
    expect(bundle.profile.label.resolve('en'), 'Bubble');
    expect(bundle.profile.description.resolve('zh'), contains('胶囊'));
    expect(bundle.profile.styleIdentity, 'dense-docked-bubble');
    expect(bundle.profile.isDefault, isFalse);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.assetNamespace, 'layout-profiles/bubble/desktop');
    expect(bundle.restorationNamespace, 'bubble.desktop');
    expect(bundle.components.styleIdentity, 'dense-docked-bubble');
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
        bubbleDesktopExpectedDestinations,
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
    final namespaces = bubbleDesktopBundle.stateNamespaces;

    expect(namespaces, hasLength(4));
    expect(namespaces.map((value) => value.destination).toSet(), {
      ClientSection.agents,
      ClientSection.settings,
    });
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('bubble'));
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
    final coverage = bubbleDesktopBundle.coverage.toList(growable: false);

    expect(coverage, hasLength(2));
    for (final entry in coverage) {
      expect(entry.key.profileId, LayoutProfileId.parse('bubble'));
      expect(entry.key.surface, LayoutRuntimeSurface.desktop);
      expect(entry.destinations, bubbleDesktopExpectedDestinations);
    }
  });

  test('preview metadata is deterministic and structurally Bubble-owned', () {
    expect(bubbleDesktopPreviewMetadata.styleIdentity, 'dense-docked-bubble');
    expect(bubbleDesktopPreviewMetadata.structuralLandmarks, <String>[
      'context-rail',
      'workspace-bar',
      'edge-editor',
      'inspector-dock',
    ]);
  });

  test('actions reject unknown action identities', () {
    final actions = BubbleActionRecorder();
    expect(
      () => actions.invokeContentAction(ClientSection.skillHub, 'unknown'),
      throwsFormatException,
    );
  });

  for (final destination in bubbleDesktopExpectedDestinations) {
    testWidgets('content adapter is exact for ${destination.name}', (
      tester,
    ) async {
      const size = Size(900, 620);
      configureBubbleTestView(tester, size);
      final actions = BubbleActionRecorder();
      final content = BubbleRecordingContentPort(actions);

      await tester.pumpWidget(
        BubbleDesktopTestHarness(
          environment: bubbleDesktopEnvironment(
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
        find.byKey(ValueKey<String>('bubble-fake-content-${destination.name}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
