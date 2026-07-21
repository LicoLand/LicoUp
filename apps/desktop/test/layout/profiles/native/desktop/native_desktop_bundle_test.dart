import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/preview/native_desktop_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/native_desktop.dart';

import './native_desktop_test_harness.dart';

void main() {
  test('bundle exposes the exact immutable Native desktop contract', () {
    final bundle = nativeDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('native'));
    expect(bundle.profile.label.resolve('en'), 'Native');
    expect(bundle.profile.description.resolve('zh'), contains('默认'));
    expect(bundle.profile.styleIdentity, 'glassy-rail-native');
    expect(bundle.profile.isDefault, isTrue);
    expect(bundle.profile.revision, 3);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.assetNamespace, 'layout-profiles/native/desktop');
    expect(bundle.restorationNamespace, 'native.desktop');
    expect(bundle.components.styleIdentity, 'glassy-rail-native');
    expect(bundle.tokens.density, lessThan(1));
    expect(bundle.tokens.cardRadius, 10);
    expect(bundle.tokens.elevation, 0);

    expect(bundle.variants.keys.toSet(), <LayoutViewportClass>{
      LayoutViewportClass.medium,
      LayoutViewportClass.expanded,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        nativeDesktopExpectedDestinations,
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
    final namespaces = nativeDesktopBundle.stateNamespaces;

    expect(namespaces, hasLength(4));
    expect(namespaces.map((value) => value.destination).toSet(), {
      ClientSection.agents,
      ClientSection.settings,
    });
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('native'));
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
    final coverage = nativeDesktopBundle.coverage.toList(growable: false);

    expect(coverage, hasLength(2));
    for (final entry in coverage) {
      expect(entry.key.profileId, LayoutProfileId.parse('native'));
      expect(entry.key.surface, LayoutRuntimeSurface.desktop);
      expect(entry.destinations, nativeDesktopExpectedDestinations);
    }
  });

  test('preview metadata is deterministic and structurally Native-owned', () {
    expect(nativeDesktopPreviewMetadata.styleIdentity, 'glassy-rail-native');
    expect(nativeDesktopPreviewMetadata.structuralLandmarks, <String>[
      'nav-rail',
      'content-card',
      'list-layer',
      'detail-layer',
    ]);
  });

  test('actions reject unknown action identities', () {
    final actions = NativeActionRecorder();
    expect(
      () => actions.invokeContentAction(ClientSection.skillHub, 'unknown'),
      throwsFormatException,
    );
  });

  for (final destination in nativeDesktopExpectedDestinations) {
    testWidgets('content adapter is exact for ${destination.name}', (
      tester,
    ) async {
      const size = Size(900, 620);
      configureNativeTestView(tester, size);
      final actions = NativeActionRecorder();
      final content = NativeRecordingContentPort(actions);

      await tester.pumpWidget(
        NativeDesktopTestHarness(
          environment: nativeDesktopEnvironment(
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
        find.byKey(ValueKey<String>('native-fake-content-${destination.name}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
