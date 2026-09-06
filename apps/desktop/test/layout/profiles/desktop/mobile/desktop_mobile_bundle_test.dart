import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/destinations/desktop_mobile_agents_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/destinations/desktop_mobile_settings_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_bundle.dart';

import '../../../fixtures/layout_scoped_state_fixture.dart';

void main() {
  group('desktop mobile bundle', () {
    test('declares one immutable exact mobile renderer product', () {
      final bundle = desktopMobileBundle;
      const expectedViewports = {
        LayoutViewportClass.compact,
        LayoutViewportClass.medium,
      };
      const expectedDestinations = {
        ClientSection.agents,
        ClientSection.mobileRelay,
        ClientSection.settings,
      };

      expect(bundle.profile.id, LayoutProfileId.parse('desktop'));
      expect(bundle.profile.label.resolve('en'), 'Desktop');
      expect(
        bundle.profile.description.resolve('zh'),
        contains('Desktop 布局'),
      );
      expect(bundle.profile.styleIdentity, 'spacious-card-desktop');
      expect(bundle.profile.isDefault, isFalse);
      expect(bundle.surface, LayoutRuntimeSurface.mobile);
      expect(bundle.variants.keys.toSet(), expectedViewports);
      expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
      expect(bundle.assetNamespace, 'layout-profiles/desktop/mobile');
      expect(bundle.restorationNamespace, 'desktop.mobile');

      for (final entry in bundle.variants.entries) {
        expect(entry.value.viewport, entry.key);
        expect(
          entry.value.destinationBuilders.keys.toSet(),
          expectedDestinations,
        );
        expect(entry.value.destinationBuilders.length, 3);
        expect(
          entry.value.destinationBuilders.containsKey(ClientSection.skillHub),
          isFalse,
        );
        expect(entry.value.destinationBuilders.clear, throwsUnsupportedError);
      }
      expect(bundle.variants.clear, throwsUnsupportedError);
      expect(bundle.stateNamespaces.clear, throwsUnsupportedError);
    });

    test('declares exact business presentation-state channels', () {
      final namespaces = desktopMobileBundle.stateNamespaces;

      expect(namespaces, hasLength(4));
      expect(namespaces.map((namespace) => namespace.destination).toSet(), {
        ClientSection.agents,
        ClientSection.settings,
      });
      for (final namespace in namespaces) {
        expect(namespace.profileId, LayoutProfileId.parse('desktop'));
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
      expect(
        desktopMobileBundle.coverage
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
              child: Builder(builder: desktopMobileBundle.previewBuilder),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('desktop-mobile-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('desktop-mobile-preview-card-stack')),
        findsOneWidget,
      );
      expect(find.text('Agents'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Agents and Settings content receive mobile strategies', (
      tester,
    ) async {
      final environment = LayoutEnvironment.fromConstraints(
        surface: LayoutRuntimeSurface.mobile,
        width: 390,
        height: 760,
        textScale: 1,
        hasTouch: true,
      );
      final content = _DesktopMobilePresentationContent();
      final variant = desktopMobileBundle.variants[environment.viewport]!;

      for (final destination in const [
        ClientSection.agents,
        ClientSection.settings,
      ]) {
        final builder = variant.destinationBuilders[destination]!;
        final state = buildLayoutScopedStateFixture(
          profile: desktopMobileBundle.profile,
          surface: LayoutRuntimeSurface.mobile,
          stateNamespaces: desktopMobileBundle.stateNamespaces,
          destination: destination,
        );
        await tester.pumpWidget(
          MaterialApp(
            restorationScopeId: 'desktop-mobile-presentation-test',
            home: Builder(
              builder: (context) => builder(
                context,
                LayoutDestinationBuildContext(
                  environment: environment,
                  destination: destination,
                  content: content,
                  state: state,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.byKey(
            ValueKey<String>('desktop-mobile-scope-${destination.name}'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }

      expect(content.agents, isA<DesktopMobileAgentsPresentation>());
      expect(content.settings, isA<DesktopMobileSettingsPresentation>());
    });
  });
}

final class _DesktopMobilePresentationContent
    implements LayoutDestinationContentPort {
  LayoutAgentsPresentation? agents;
  LayoutSettingsPresentation? settings;

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    switch (destination) {
      case ClientSection.agents:
        agents = LayoutDestinationPresentationScope.agentsOf(context);
      case ClientSection.settings:
        settings = LayoutDestinationPresentationScope.settingsOf(context);
      default:
        throw const FormatException(
          'desktop_mobile_scope_test_destination_invalid',
        );
    }
    return SizedBox(
      key: ValueKey<String>('desktop-mobile-scope-${destination.name}'),
    );
  }
}
