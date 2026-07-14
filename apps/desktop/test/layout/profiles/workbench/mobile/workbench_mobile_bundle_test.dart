import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_bundle.dart';

import './workbench_mobile_test_fakes.dart';

void main() {
  group('workbench mobile bundle', () {
    test('declares one immutable exact mobile renderer product', () {
      final bundle = workbenchMobileBundle;
      const expectedViewports = {
        LayoutViewportClass.compact,
        LayoutViewportClass.medium,
      };
      const expectedDestinations = {
        ClientSection.agents,
        ClientSection.feed,
        ClientSection.mobileRelay,
        ClientSection.settings,
      };

      expect(bundle.profile.id, LayoutProfileId.workbench);
      expect(bundle.profile.labelKey, 'layout.profile.workbench.label');
      expect(
        bundle.profile.descriptionKey,
        'layout.profile.workbench.description',
      );
      expect(bundle.profile.styleIdentity, 'spacious-card-workbench');
      expect(bundle.profile.isDefault, isTrue);
      expect(bundle.surface, LayoutRuntimeSurface.mobile);
      expect(bundle.variants.keys.toSet(), expectedViewports);
      expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
      expect(bundle.assetNamespace, 'layout-profiles/workbench/mobile');
      expect(bundle.restorationNamespace, 'workbench.mobile');

      for (final entry in bundle.variants.entries) {
        expect(entry.value.viewport, entry.key);
        expect(
          entry.value.destinationBuilders.keys.toSet(),
          expectedDestinations,
        );
        expect(entry.value.destinationBuilders.length, 4);
        expect(
          entry.value.destinationBuilders.containsKey(ClientSection.skillHub),
          isFalse,
        );
        expect(entry.value.destinationBuilders.clear, throwsUnsupportedError);
      }
      expect(bundle.variants.clear, throwsUnsupportedError);
      expect(bundle.stateNamespaces.clear, throwsUnsupportedError);
    });

    test('declares one bounded content-scroll namespace per destination', () {
      final namespaces = workbenchMobileBundle.stateNamespaces;

      expect(namespaces, hasLength(4));
      expect(
        namespaces.map((namespace) => namespace.destination).toSet(),
        workbenchMobileTestDestinations.toSet(),
      );
      for (final namespace in namespaces) {
        expect(namespace.profileId, LayoutProfileId.workbench);
        expect(namespace.surface, LayoutRuntimeSurface.mobile);
        expect(namespace.surfaceId, 'content-scroll');
      }
      expect(
        workbenchMobileBundle.coverage
            .map((coverage) => coverage.key.viewport)
            .toSet(),
        {LayoutViewportClass.compact, LayoutViewportClass.medium},
      );
    });

    testWidgets('builds a metadata-only preview from appearance input', (
      tester,
    ) async {
      final colorScheme = ColorScheme.fromSeed(
        seedColor: const Color(0xff3d5a80),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true, colorScheme: colorScheme),
          home: Center(
            child: SizedBox(
              width: 220,
              child: Builder(builder: workbenchMobileBundle.previewBuilder),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('workbench-mobile-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workbench-mobile-preview-card-stack')),
        findsOneWidget,
      );
      expect(find.text('Agents'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
