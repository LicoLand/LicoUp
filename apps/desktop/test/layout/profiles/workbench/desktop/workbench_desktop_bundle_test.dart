import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_agents_presentation.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_settings_presentation.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/workbench_desktop.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../fixtures/layout_scoped_state_fixture.dart';
import './workbench_desktop_test_harness.dart';

void main() {
  test('exports the exact immutable workbench desktop bundle', () {
    final bundle = workbenchDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('workbench'));
    expect(bundle.profile.label.resolve('en'), 'Lico Arc');
    expect(bundle.profile.description.resolve('zh'), contains('标准布局'));
    expect(bundle.profile.styleIdentity, 'spacious-card-workbench');
    expect(bundle.profile.isDefault, isFalse);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.assetNamespace, 'layout-profiles/workbench/desktop');
    expect(bundle.restorationNamespace, 'workbench.desktop');
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
    final coverage = workbenchDesktopBundle.coverage.toList();

    expect(coverage, hasLength(2));
    for (final entry in workbenchDesktopBundle.variants.entries) {
      expect(entry.value.viewport, entry.key);
      expect(
        entry.value.destinationBuilders.keys.toSet(),
        workbenchDesktopCanonicalDestinations,
      );
      expect(
        () => entry.value.destinationBuilders.remove(ClientSection.agents),
        throwsUnsupportedError,
      );
    }
    for (final entry in coverage) {
      expect(entry.key.profileId, LayoutProfileId.parse('workbench'));
      expect(entry.key.surface, LayoutRuntimeSurface.desktop);
      expect(entry.destinations, workbenchDesktopCanonicalDestinations);
    }
  });

  test('declares exact business presentation-state channels', () {
    final namespaces = workbenchDesktopBundle.stateNamespaces;
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

  testWidgets('Agents and Settings content receive Workbench strategies', (
    tester,
  ) async {
    final environment = workbenchDesktopEnvironment(width: 900, height: 720);
    final state = buildLayoutScopedStateFixture(
      profile: workbenchDesktopBundle.profile,
      surface: LayoutRuntimeSurface.desktop,
      stateNamespaces: workbenchDesktopBundle.stateNamespaces,
    );
    final content = _WorkbenchPresentationContent();
    final variant = workbenchDesktopBundle.variants[environment.viewport]!;
    final base = buildLicoTheme(
      presetId: 'geek-light-blue',
      platformBrightness: Brightness.light,
    );
    final theme = base.copyWith(
      extensions: [...base.extensions.values, workbenchDesktopBundle.tokens],
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
        find.byKey(ValueKey<String>('workbench-scope-${destination.name}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }

    expect(content.agents, isA<WorkbenchDesktopAgentsPresentation>());
    expect(content.settings, isA<WorkbenchDesktopSettingsPresentation>());
  });
}

final class _WorkbenchPresentationContent
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
        throw const FormatException('workbench_scope_test_destination_invalid');
    }
    return SizedBox(
      key: ValueKey<String>('workbench-scope-${destination.name}'),
    );
  }
}
