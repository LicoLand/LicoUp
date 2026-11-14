import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/dashboard_desktop.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_card_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_plain_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/preview/dashboard_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_card_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_plain_shell.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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
      dashboardCardPreviewMetadata.styleIdentity,
      'dashboard-channel-chat',
    );
    expect(dashboardCardPreviewMetadata.structuralLandmarks, <String>[
      'traffic-light-row',
      'list-column',
      'chat-canvas',
    ]);
  });

  test("selector cards align with the setting rows' leading edge", () {
    final rows = dashboardPlainSettingsPresentation.rowPadding.resolve(
      TextDirection.ltr,
    );
    final grid = dashboardPlainSettingsPresentation.selectorGridPadding.resolve(
      TextDirection.ltr,
    );
    expect(grid.left, rows.left, reason: 'selector left == row left');
    expect(grid.right, rows.right, reason: 'selector right == row right');
  });

  testWidgets('settings sections render as shared info-glass cards', (
    tester,
  ) async {
    for (final presentation in [
      dashboardPlainSettingsPresentation,
      dashboardCardSettingsPresentation,
    ]) {
      const sectionKey = Key('settings-section-under-test');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => presentation.frameSection(
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
      expect(card, findsOneWidget, reason: '$presentation section card');
      final material = tester.widget<Material>(
        find.descendant(of: card, matching: find.byType(Material)).first,
      );
      expect(
        material.color,
        LicoPaneGlass.contentInnerCardFill,
        reason: '$presentation section fill',
      );
      final shape = material.shape! as ContinuousRoundedBorder;
      expect(
        shape.side.color,
        LicoPaneGlass.contentInnerCardRim,
        reason: '$presentation section rim',
      );
    }
  });

  testWidgets('first settings section card is inset by the page padding', (
    tester,
  ) async {
    const pagePadding = EdgeInsets.symmetric(horizontal: 26, vertical: 22);
    for (final presentation in [
      dashboardPlainSettingsPresentation,
      dashboardCardSettingsPresentation,
    ]) {
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
                    child: presentation.frameSection(
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
      expect(
        cardRect.top,
        closeTo(bounds.top + pagePadding.top, 0.5),
        reason: '$presentation top inset',
      );
      expect(
        cardRect.left,
        closeTo(bounds.left + pagePadding.left, 0.5),
        reason: '$presentation left inset',
      );
      expect(
        cardRect.right,
        lessThanOrEqualTo(bounds.right),
        reason: '$presentation right inset',
      );
    }
  });

  test('the plain dashboard picks starlight in dark and lamp in light', () {
    final dark = layoutPaletteFromColors(
      licoColorsFor('lico-starlit-gold', platformBrightness: Brightness.dark),
    );
    final light = layoutPaletteFromColors(
      licoColorsFor('lico-taro-waffle', platformBrightness: Brightness.light),
    );
    expect(
      dashboardPlainSelectionTreatment(dark),
      LicoSelectionTreatment.starlight,
    );
    expect(
      dashboardPlainSelectionTreatment(light),
      LicoSelectionTreatment.lamp,
    );
    expect(
      dashboardCardSelectionTreatment(dark),
      LicoSelectionTreatment.starlight,
    );
    expect(dashboardCardSelectionTreatment(light), LicoSelectionTreatment.lamp);
  });
}
