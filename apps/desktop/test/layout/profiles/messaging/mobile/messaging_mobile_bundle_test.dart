import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_bundle.dart';

import 'messaging_mobile_test_harness.dart';

void main() {
  test('bundle exposes the exact immutable Messaging mobile contract', () {
    final bundle = messagingMobileBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('messaging'));
    expect(bundle.profile.label.resolve('en'), 'Default');
    expect(bundle.profile.label.resolve('zh'), '默认');
    expect(bundle.profile.styleIdentity, 'messaging-channel-chat');
    expect(bundle.profile.isDefault, isTrue);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.mobile);
    expect(bundle.assetNamespace, 'layout-profiles/messaging/mobile');
    expect(bundle.restorationNamespace, 'messaging.mobile');
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.variants.keys.toSet(), {
      LayoutViewportClass.compact,
      LayoutViewportClass.medium,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        messagingMobileExpectedDestinations,
      );
    }
  });

  test('state namespaces mirror the desktop channels per surface', () {
    final namespaces = messagingMobileBundle.stateNamespaces;

    expect(namespaces, hasLength(4));
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('messaging'));
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
