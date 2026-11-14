import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/destinations/desktop_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/presentation/desktop_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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

  test("selector cards align with the setting rows' leading edge", () {
    final rows = desktopDesktopSettingsPresentation.rowPadding.resolve(
      TextDirection.ltr,
    );
    final grid = desktopDesktopSettingsPresentation.selectorGridPadding.resolve(
      TextDirection.ltr,
    );
    expect(grid.left, rows.left, reason: 'selector left == row left');
    expect(grid.right, rows.right, reason: 'selector right == row right');
  });

  testWidgets('settings sections render as shared info-glass cards', (
    tester,
  ) async {
    const sectionKey = Key('settings-section-under-test');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                desktopDesktopSettingsPresentation.frameSection(
                  context,
                  key: sectionKey,
                  child: const SizedBox(height: 60),
                ),
          ),
        ),
      ),
    );
    final sectionFinder = find.byKey(sectionKey);
    expect(sectionFinder, findsOneWidget);
    final card = find.descendant(
      of: sectionFinder,
      matching: find.byType(Card),
    );
    expect(card, findsOneWidget);
    final material = tester.widget<Material>(
      find.descendant(of: card, matching: find.byType(Material)).first,
    );
    expect(material.color, LicoPaneGlass.contentInnerCardFill);
    final shape = material.shape! as ContinuousRoundedBorder;
    expect(shape.side.color, LicoPaneGlass.contentInnerCardRim);
  });

  testWidgets('first settings section card is inset by the page padding', (
    tester,
  ) async {
    const pagePadding = EdgeInsets.symmetric(horizontal: 26, vertical: 22);
    const sectionKey = Key('inset-section');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox.expand(
            child: Padding(
              key: const Key('page-content'),
              padding: pagePadding,
              child: Builder(
                builder: (context) => Align(
                  alignment: Alignment.topLeft,
                  child: desktopDesktopSettingsPresentation.frameSection(
                    context,
                    key: sectionKey,
                    child: const SizedBox(height: 60),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final cardRect = tester.getRect(find.byType(Card));
    final bounds = tester.getRect(find.byKey(const Key('page-content')));
    expect(cardRect.top, closeTo(bounds.top + pagePadding.top, 0.5));
    expect(cardRect.left, closeTo(bounds.left + pagePadding.left, 0.5));
    expect(cardRect.right, lessThanOrEqualTo(bounds.right));
  });
}
