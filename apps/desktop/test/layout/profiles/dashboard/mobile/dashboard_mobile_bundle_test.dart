import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_bundle.dart';

import 'dashboard_mobile_test_harness.dart';

void main() {
  test('bundle exposes the exact immutable Dashboard mobile contract', () {
    final bundle = dashboardMobileBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('dashboard'));
    expect(bundle.profile.label.resolve('en'), 'Dashboard');
    expect(bundle.profile.label.resolve('zh'), '仪表盘');
    expect(bundle.profile.styleIdentity, 'dashboard-channel-chat');
    expect(bundle.profile.isDefault, isTrue);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.mobile);
    expect(bundle.assetNamespace, 'layout-profiles/dashboard/mobile');
    expect(bundle.restorationNamespace, 'dashboard.mobile');
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.variants.keys.toSet(), {
      LayoutViewportClass.compact,
      LayoutViewportClass.medium,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        dashboardMobileExpectedDestinations,
      );
    }
  });

  test('state namespaces mirror the desktop channels per surface', () {
    final namespaces = dashboardMobileBundle.stateNamespaces;

    expect(namespaces, hasLength(4));
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
  });
}
