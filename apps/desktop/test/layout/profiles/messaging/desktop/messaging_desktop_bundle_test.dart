import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/composition/built_in_layout_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/messaging_desktop.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/preview/messaging_desktop_preview.dart';

import 'messaging_desktop_test_harness.dart';

void main() {
  test('bundle exposes the exact immutable Messaging desktop contract', () {
    final bundle = messagingDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('messaging'));
    expect(bundle.profile.label.resolve('en'), 'Default');
    expect(bundle.profile.label.resolve('zh'), '默认');
    expect(
      bundle.profile.description.resolve('en'),
      contains('Default layout'),
    );
    expect(bundle.profile.description.resolve('zh'), contains('默认'));
    expect(bundle.profile.styleIdentity, 'messaging-channel-chat');
    expect(bundle.profile.isDefault, isTrue);
    expect(bundle.profile.revision, 1);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.assetNamespace, 'layout-profiles/messaging/desktop');
    expect(bundle.restorationNamespace, 'messaging.desktop');
    expect(bundle.components.styleIdentity, 'messaging-channel-chat');

    expect(bundle.variants.keys.toSet(), <LayoutViewportClass>{
      LayoutViewportClass.medium,
      LayoutViewportClass.expanded,
    });
    for (final variant in bundle.variants.values) {
      expect(
        variant.destinationBuilders.keys.toSet(),
        messagingDesktopExpectedDestinations,
      );
    }
  });

  test('state namespaces are profile-qualified and business-scoped', () {
    final namespaces = messagingDesktopBundle.stateNamespaces;

    expect(namespaces, hasLength(6));
    expect(namespaces.map((value) => value.destination).toSet(), {
      ClientSection.agents,
      ClientSection.settings,
      ClientSection.models,
    });
    for (final namespace in namespaces) {
      expect(namespace.profileId, LayoutProfileId.parse('messaging'));
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

  test('composition registers Messaging on both surfaces with one default', () {
    final composition = BuiltInLayoutComposition();
    final messagingId = LayoutProfileId.parse('messaging');

    final profile = composition.catalog.profile(messagingId);
    expect(profile, isNotNull);
    expect(profile!.styleIdentity, 'messaging-channel-chat');
    expect(profile.isDefault, isTrue);
    expect(
      composition
          .previewBundle(messagingId, LayoutRuntimeSurface.desktop)
          .surface,
      LayoutRuntimeSurface.desktop,
    );
    expect(
      composition
          .previewBundle(messagingId, LayoutRuntimeSurface.mobile)
          .surface,
      LayoutRuntimeSurface.mobile,
    );
    expect(
      composition.settingsProfiles.where((value) => value.isDefault),
      hasLength(1),
    );
    expect(
      composition.settingsProfiles.map((value) => value.styleIdentity).toSet(),
      hasLength(composition.settingsProfiles.length),
    );
  });

  test('preview metadata is deterministic and Messaging-owned', () {
    expect(
      messagingDesktopPreviewMetadata.styleIdentity,
      'messaging-channel-chat',
    );
    expect(messagingDesktopPreviewMetadata.structuralLandmarks, <String>[
      'top-strip',
      'list-column',
      'chat-canvas',
    ]);
  });
}
