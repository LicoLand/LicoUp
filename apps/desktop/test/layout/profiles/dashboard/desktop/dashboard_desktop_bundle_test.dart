import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/dashboard_desktop.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/preview/dashboard_desktop_preview.dart';

import 'dashboard_desktop_test_harness.dart';

void main() {
  test('bundle exposes the exact immutable Dashboard desktop contract', () {
    final bundle = dashboardDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('dashboard'));
    expect(bundle.profile.label.resolve('en'), 'Dashboard');
    expect(bundle.profile.label.resolve('zh'), '仪表盘');
    expect(
      bundle.profile.description.resolve('en'),
      contains('Dashboard layout'),
    );
    expect(bundle.profile.description.resolve('zh'), contains('Dashboard'));
    expect(bundle.profile.styleIdentity, 'dashboard-channel-chat');
    expect(bundle.profile.isDefault, isTrue);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.assetNamespace, 'layout-profiles/dashboard/desktop');
    expect(bundle.restorationNamespace, 'dashboard.desktop');
    expect(bundle.components.styleIdentity, 'dashboard-channel-chat');

    expect(bundle.variants.keys.toSet(), <LayoutViewportClass>{
      LayoutViewportClass.medium,
      LayoutViewportClass.expanded,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        dashboardDesktopExpectedDestinations,
      );
    }
  });

  test('state namespaces are profile-qualified and business-scoped', () {
    final namespaces = dashboardDesktopBundle.stateNamespaces;

    expect(namespaces, hasLength(6));
    expect(namespaces.map((value) => value.destination).toSet(), {
      ClientSection.agents,
      ClientSection.settings,
      ClientSection.models,
    });
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('dashboard'));
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
        LayoutStateChannels.settingsIndex.id,
      },
    );
    expect(
      namespaces
          .where((value) => value.destination == ClientSection.models)
          .map((value) => value.surfaceId)
          .toSet(),
      {LayoutStateChannels.communicationSection.id},
    );
  });

  test('preview metadata is deterministic and Dashboard-owned', () {
    expect(
      dashboardDesktopPreviewMetadata.styleIdentity,
      'dashboard-channel-chat',
    );
    expect(dashboardDesktopPreviewMetadata.structuralLandmarks, <String>[
      'traffic-light-row',
      'list-column',
      'chat-canvas',
    ]);
  });
}
