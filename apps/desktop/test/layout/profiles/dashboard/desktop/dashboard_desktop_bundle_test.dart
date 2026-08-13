import 'package:flutter/material.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_agents_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_settings_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/dashboard_desktop.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../fixtures/layout_scoped_state_fixture.dart';
import './dashboard_desktop_test_harness.dart';

void main() {
  test('exports the exact immutable dashboard desktop bundle', () {
    final bundle = dashboardDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('dashboard'));
    expect(bundle.profile.label.resolve('en'), 'Dashboard');
    expect(bundle.profile.description.resolve('zh'), contains('Dashboard 布局'));
    expect(bundle.profile.styleIdentity, 'spacious-card-dashboard');
    expect(bundle.profile.isDefault, isFalse);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.assetNamespace, 'layout-profiles/dashboard/desktop');
    expect(bundle.restorationNamespace, 'dashboard.desktop');
    expect(bundle.variants.keys.toSet(), {
      LayoutViewportClass.medium,
      LayoutViewportClass.expanded,
    });
    expect(
      () => bundle.variants.remove(LayoutViewportClass.medium),
      throwsUnsupportedError,
    );
  });

  test('each viewport declares the same exact canonical destinations', () {
    final coverage = dashboardDesktopBundle.coverage.toList();

    expect(coverage, hasLength(2));
    for (final entry in dashboardDesktopBundle.variants.entries) {
      expect(entry.value.viewport, entry.key);
      expect(
        entry.value.destinationBuilders.keys.toSet(),
        dashboardDesktopCanonicalDestinations,
      );
      expect(
        () => entry.value.destinationBuilders.remove(ClientSection.agents),
        throwsUnsupportedError,
      );
    }
    for (final entry in coverage) {
      expect(entry.key.profileId, LayoutProfileId.parse('dashboard'));
      expect(entry.key.surface, LayoutRuntimeSurface.desktop);
      expect(entry.destinations, dashboardDesktopCanonicalDestinations);
    }
  });

  test('declares exact business presentation-state channels', () {
    final namespaces = dashboardDesktopBundle.stateNamespaces;
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
    expect(() => namespaces.clear(), throwsUnsupportedError);
  });

  testWidgets('Agents and Settings content receive Dashboard strategies', (
    tester,
  ) async {
    final environment = dashboardDesktopEnvironment(width: 900, height: 720);
    final state = buildLayoutScopedStateFixture(
      profile: dashboardDesktopBundle.profile,
      surface: LayoutRuntimeSurface.desktop,
      stateNamespaces: dashboardDesktopBundle.stateNamespaces,
    );
    final content = _DashboardPresentationContent();
    final variant = dashboardDesktopBundle.variants[environment.viewport]!;
    final base = buildLicoTheme(
      presetId: 'geek-light-blue',
      platformBrightness: Brightness.light,
    );
    final theme = base.copyWith(
      extensions: [...base.extensions.values, dashboardDesktopBundle.tokens],
    );

    for (final destination in const [
      ClientSection.agents,
      ClientSection.settings,
    ]) {
      final builder = variant.destinationBuilders[destination]!;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
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
        find.byKey(ValueKey<String>('dashboard-scope-${destination.name}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }

    expect(content.agents, isA<DashboardDesktopAgentsPresentation>());
    expect(content.settings, isA<DashboardDesktopSettingsPresentation>());
  });
}

final class _DashboardPresentationContent
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
        throw const FormatException('dashboard_scope_test_destination_invalid');
    }
    return SizedBox(
      key: ValueKey<String>('dashboard-scope-${destination.name}'),
    );
  }
}
