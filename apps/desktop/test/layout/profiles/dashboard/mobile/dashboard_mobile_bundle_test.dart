import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_mobile_agents_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_mobile_settings_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_bundle.dart';

import '../../../fixtures/layout_scoped_state_fixture.dart';

void main() {
  group('dashboard mobile bundle', () {
    test('declares one immutable exact mobile renderer product', () {
      final bundle = dashboardMobileBundle;
      const expectedViewports = {
        LayoutViewportClass.compact,
        LayoutViewportClass.medium,
      };
      const expectedDestinations = {
        ClientSection.agents,
        ClientSection.mobileRelay,
        ClientSection.settings,
      };

      expect(bundle.profile.id, LayoutProfileId.parse('dashboard'));
      expect(bundle.profile.label.resolve('en'), 'Dashboard');
      expect(
        bundle.profile.description.resolve('zh'),
        contains('Dashboard 布局'),
      );
      expect(bundle.profile.styleIdentity, 'spacious-card-dashboard');
      expect(bundle.profile.isDefault, isFalse);
      expect(bundle.surface, LayoutRuntimeSurface.mobile);
      expect(bundle.variants.keys.toSet(), expectedViewports);
      expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
      expect(bundle.assetNamespace, 'layout-profiles/dashboard/mobile');
      expect(bundle.restorationNamespace, 'dashboard.mobile');

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
      final namespaces = dashboardMobileBundle.stateNamespaces;

      expect(namespaces, hasLength(4));
      expect(namespaces.map((namespace) => namespace.destination).toSet(), {
        ClientSection.agents,
        ClientSection.settings,
      });
      for (final namespace in namespaces) {
        expect(namespace.profileId, LayoutProfileId.parse('dashboard'));
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
        dashboardMobileBundle.coverage
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
              child: Builder(builder: dashboardMobileBundle.previewBuilder),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('dashboard-mobile-preview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dashboard-mobile-preview-card-stack')),
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
      final content = _DashboardMobilePresentationContent();
      final variant = dashboardMobileBundle.variants[environment.viewport]!;

      for (final destination in const [
        ClientSection.agents,
        ClientSection.settings,
      ]) {
        final builder = variant.destinationBuilders[destination]!;
        final state = buildLayoutScopedStateFixture(
          profile: dashboardMobileBundle.profile,
          surface: LayoutRuntimeSurface.mobile,
          stateNamespaces: dashboardMobileBundle.stateNamespaces,
          destination: destination,
        );
        await tester.pumpWidget(
          MaterialApp(
            restorationScopeId: 'dashboard-mobile-presentation-test',
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
            ValueKey<String>('dashboard-mobile-scope-${destination.name}'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }

      expect(content.agents, isA<DashboardMobileAgentsPresentation>());
      expect(content.settings, isA<DashboardMobileSettingsPresentation>());
    });
  });
}

final class _DashboardMobilePresentationContent
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
          'dashboard_mobile_scope_test_destination_invalid',
        );
    }
    return SizedBox(
      key: ValueKey<String>('dashboard-mobile-scope-${destination.name}'),
    );
  }
}
