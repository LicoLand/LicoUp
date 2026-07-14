import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/workbench_desktop.dart';
import 'package:flutter_test/flutter_test.dart';

import './workbench_desktop_test_harness.dart';

void main() {
  test('exports the exact immutable workbench desktop bundle', () {
    final bundle = workbenchDesktopBundle;

    expect(bundle.profile.id, LayoutProfileId.workbench);
    expect(bundle.profile.labelKey, 'layout.profile.workbench.label');
    expect(
      bundle.profile.descriptionKey,
      'layout.profile.workbench.description',
    );
    expect(bundle.profile.styleIdentity, 'spacious-card-workbench');
    expect(bundle.profile.isDefault, isTrue);
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
      expect(entry.key.profileId, LayoutProfileId.workbench);
      expect(entry.key.surface, LayoutRuntimeSurface.desktop);
      expect(entry.destinations, workbenchDesktopCanonicalDestinations);
    }
  });

  test('declares one bounded content-scroll namespace per destination', () {
    final expected = {
      for (final destination in workbenchDesktopCanonicalDestinations)
        LayoutStateNamespace(
          profileId: LayoutProfileId.workbench,
          surface: LayoutRuntimeSurface.desktop,
          destination: destination,
          surfaceId: 'content-scroll',
        ),
    };

    expect(workbenchDesktopBundle.stateNamespaces, expected);
    expect(workbenchDesktopBundle.stateNamespaces, hasLength(7));
    expect(
      () => workbenchDesktopBundle.stateNamespaces.clear(),
      throwsUnsupportedError,
    );
  });
}
