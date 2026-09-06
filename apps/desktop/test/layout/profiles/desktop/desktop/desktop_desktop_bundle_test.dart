import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/destinations/desktop_desktop_destination_builders.dart';

void main() {
  test('exports the exact immutable Desktop desktop bundle', () {
    final bundle = desktopDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.parse('desktop'));
    expect(bundle.profile.label.resolve('en'), 'Desktop');
    expect(bundle.profile.styleIdentity, 'spacious-card-desktop');
    expect(bundle.profile.isDefault, isFalse);
    expect(bundle.profile.selectable, isTrue);
    expect(bundle.surface, LayoutRuntimeSurface.desktop);
    expect(bundle.components.styleIdentity, bundle.profile.styleIdentity);
    expect(bundle.assetNamespace, 'layout-profiles/desktop/desktop');
    expect(bundle.restorationNamespace, 'desktop.desktop');
    expect(bundle.variants.keys.toSet(), {
      LayoutViewportClass.medium,
      LayoutViewportClass.expanded,
    });
    expect(
      () => bundle.variants.remove(LayoutViewportClass.medium),
      throwsUnsupportedError,
    );
  });

  test('each viewport declares the full canonical destination set', () {
    final coverage = desktopDesktopBundle.coverage.toList();
    expect(coverage, hasLength(2));
    for (final entry in desktopDesktopBundle.variants.entries) {
      expect(entry.value.viewport, entry.key);
      expect(
        entry.value.destinationBuilders.keys.toSet(),
        ClientSection.values.toSet(),
      );
      expect(
        () => entry.value.destinationBuilders.remove(ClientSection.agents),
        throwsUnsupportedError,
      );
    }
    for (final entry in coverage) {
      expect(entry.key.profileId, LayoutProfileId.parse('desktop'));
      expect(entry.key.surface, LayoutRuntimeSurface.desktop);
      expect(entry.destinations, ClientSection.values.toSet());
    }
  });

  test('declares the desktop state namespaces including pane channels', () {
    final namespaces = desktopDesktopBundle.stateNamespaces;
    expect(
      namespaces,
      containsAll(BuiltInLayoutSpec.desktopDesktopStateNamespaces),
    );
    expect(
      namespaces
          .where((value) => value.destination == ClientSection.models)
          .map((value) => value.surfaceId)
          .toSet(),
      {LayoutStateChannels.communicationSection.id},
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
    expect(() => namespaces.clear(), throwsUnsupportedError);
  });

  test('destination builder table stays unmodifiable', () {
    expect(
      () => desktopDesktopDestinationBuilders.remove(ClientSection.agents),
      throwsUnsupportedError,
    );
  });
}
