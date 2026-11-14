import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_card_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_plain_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/presentation/desktop_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('scope exposes strategies without a profile identity', (
    tester,
  ) async {
    const agents = _AgentsPresentation();
    const settings = _SettingsPresentation();
    LayoutAgentsPresentation? foundAgents;
    LayoutSettingsPresentation? foundSettings;

    await tester.pumpWidget(
      LayoutDestinationPresentationScope(
        agents: agents,
        settings: settings,
        child: Builder(
          builder: (context) {
            foundAgents = LayoutDestinationPresentationScope.agentsOf(context);
            foundSettings = LayoutDestinationPresentationScope.settingsOf(
              context,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    expect(foundAgents, same(agents));
    expect(foundSettings, same(settings));
  });

  testWidgets('missing destination strategies fail closed', (tester) async {
    Object? agentsError;
    Object? settingsError;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          try {
            LayoutDestinationPresentationScope.agentsOf(context);
          } catch (value) {
            agentsError = value;
          }
          try {
            LayoutDestinationPresentationScope.settingsOf(context);
          } catch (value) {
            settingsError = value;
          }
          return const SizedBox();
        },
      ),
    );

    expect(agentsError, isA<StateError>());
    expect(settingsError, isA<StateError>());
  });

  test("selector cards align with the setting rows' leading edge", () {
    for (final presentation in [
      dashboardPlainSettingsPresentation,
      desktopDesktopSettingsPresentation,
    ]) {
      final rows = presentation.rowPadding.resolve(TextDirection.ltr);
      final grid = presentation.selectorGridPadding.resolve(TextDirection.ltr);
      expect(grid.left, rows.left, reason: 'selector left == row left');
      expect(grid.right, rows.right, reason: 'selector right == row right');
    }
  });

  testWidgets('settings sections render as shared info-glass cards', (
    tester,
  ) async {
    // The section container's RENDERED fill must be the shared
    // contentInnerCardFill in dark — not the widget type alone.
    for (final presentation in [
      dashboardPlainSettingsPresentation,
      dashboardCardSettingsPresentation,
      desktopDesktopSettingsPresentation,
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
      // The rendered fill lives on the Card's Material descendant.
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
    // The page padding insets the section card from the content bounds in
    // every presentation — the card never touches the pane edges.
    const pagePadding = EdgeInsets.symmetric(horizontal: 26, vertical: 22);
    for (final presentation in [
      dashboardPlainSettingsPresentation,
      dashboardCardSettingsPresentation,
      desktopDesktopSettingsPresentation,
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
}

final class _AgentsPresentation implements LayoutAgentsPresentation {
  const _AgentsPresentation();

  @override
  Color canvasColor(LayoutPalette palette) => palette.background;

  @override
  bool get canvasGroundsWorkspace => true;

  @override
  EdgeInsetsGeometry get collapsedSidebarControlPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get expandedSidebarControlPadding => EdgeInsets.zero;

  @override
  double get detailOuterHorizontalExtent => 0;

  @override
  bool get showCollapsedSidebarControl => false;

  @override
  bool get showConversationSidebarControl => true;

  @override
  bool get showSidebarBottomNav => true;

  @override
  LayoutAgentsSidebarHeader get sidebarHeader =>
      LayoutAgentsSidebarHeader.trafficLights;

  @override
  bool get showConversationFilters => false;

  @override
  LayoutConversationHeaderStyle get conversationHeaderStyle =>
      LayoutConversationHeaderStyle.capsules;

  @override
  double get conversationHeaderBarExtent => 60;

  @override
  LayoutGroupMembersPlacement get groupMembersPlacement =>
      LayoutGroupMembersPlacement.avatarStrip;

  @override
  bool get showExpandedSidebarControl => false;

  @override
  double get sidebarOuterHorizontalExtent => 0;

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameWorkspace(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);
}

final class _SettingsPresentation implements LayoutSettingsPresentation {
  const _SettingsPresentation();

  @override
  bool get indexHostedByNavigation => false;

  @override
  EdgeInsetsGeometry get contentPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get indexPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get rowPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get sectionHeaderPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get selectorGridPadding => EdgeInsets.zero;

  @override
  Widget frameIndex(
    BuildContext context, {
    required bool hovered,
    required Widget child,
  }) => child;

  @override
  Widget frameSection(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
