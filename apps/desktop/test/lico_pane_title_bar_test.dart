import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_title_bar.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('pane title and refresh share one vertical centerline', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: LicoPaneTitleBar(
            title: 'Pane Title',
            refreshTooltip: 'Refresh',
            onRefresh: () => taps += 1,
            refreshButtonKey: const Key('pane-refresh'),
          ),
        ),
      ),
    );

    final title = tester.getRect(find.text('Pane Title'));
    final refresh = tester.getRect(find.byKey(const Key('pane-refresh')));
    final bar = tester.getRect(find.byType(LicoPaneTitleBar));
    expect((title.center.dy - refresh.center.dy).abs(), lessThan(1));
    expect(refresh.right, closeTo(bar.right, 1));
    expect(refresh.left, greaterThan(title.right));
    expect(refresh.width, LicoIconButtonSize.medium.extent);
    expect(refresh.height, LicoIconButtonSize.medium.extent);

    final button = tester.widget<LicoIconButton>(find.byType(LicoIconButton));
    expect(button.shape, LicoIconButtonShape.circle);
    expect(button.tone, LicoIconButtonTone.ghost);
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await tester.tap(find.byKey(const Key('pane-refresh')));
    expect(taps, 1);
  });

  testWidgets('trailing search shares the refresh centerline', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: const Scaffold(
          body: LicoPaneTitleBar(
            title: 'Pane Title',
            refreshTooltip: 'Refresh',
            onRefresh: null,
            refreshButtonKey: Key('pane-refresh'),
            trailing: SizedBox(key: Key('pane-search'), width: 120, height: 32),
          ),
        ),
      ),
    );

    final title = tester.getRect(find.text('Pane Title'));
    final search = tester.getRect(find.byKey(const Key('pane-search')));
    final refresh = tester.getRect(find.byKey(const Key('pane-refresh')));
    expect((title.center.dy - search.center.dy).abs(), lessThan(1));
    expect((search.center.dy - refresh.center.dy).abs(), lessThan(1));
    expect(search.left, greaterThan(title.right));
    expect(refresh.left, greaterThan(search.right));
    final bar = tester.getRect(find.byType(LicoPaneTitleBar));
    expect(refresh.right, closeTo(bar.right, 1));
  });

  testWidgets('refreshing pane title bar spins the shared refresh glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        builder: (context, child) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          );
        },
        home: const Scaffold(
          body: LicoPaneTitleBar(
            title: 'Pane Title',
            refreshTooltip: 'Refresh',
            onRefresh: null,
            refreshing: true,
            refreshingIconKey: Key('pane-refresh-spin'),
          ),
        ),
      ),
    );

    expect(find.byType(LicoSpinningRefreshIcon), findsOneWidget);
    expect(find.byKey(const Key('pane-refresh-spin')), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });
}
