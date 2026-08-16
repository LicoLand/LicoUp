import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('title-to-top equals title-to-container and cards sit inset', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: const Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: LicoPaneScaffold(
              titleBarKey: Key('pane-title-bar'),
              contentKey: Key('pane-content'),
              title: 'Pane Title',
              refreshTooltip: 'Refresh',
              onRefresh: null,
              refreshButtonKey: Key('pane-refresh'),
              body: ColoredBox(key: Key('pane-card'), color: Color(0xFF112233)),
            ),
          ),
        ),
      ),
    );

    final pane = tester.getRect(find.byType(LicoPaneScaffold));
    final title = tester.getRect(find.text('Pane Title'));
    final card = tester.getRect(find.byKey(const Key('pane-card')));
    final refresh = tester.getRect(find.byKey(const Key('pane-refresh')));

    expect(title.left, closeTo(card.left, 1));
    expect(
      (title.top - pane.top - (card.top - title.bottom)).abs(),
      lessThan(2),
    );
    expect(LicoContentSpacing.paneTitleGap, 18);
    expect(LicoContentSpacing.paneTitlePadding.top, 18);
    expect(LicoContentSpacing.paneContentPadding.top, 18);
    expect(card.left, LicoContentSpacing.paneContentPadding.left);
    expect((title.center.dy - refresh.center.dy).abs(), lessThan(1));

    final titleBar = tester.getRect(find.byKey(const Key('pane-title-bar')));
    final content = tester.getRect(find.byKey(const Key('pane-content')));
    expect(titleBar.width, closeTo(content.width, 1));
    expect(titleBar.left, closeTo(content.left, 1));
    expect(refresh.right, closeTo(card.right, 1));
    expect(refresh.left, greaterThan(title.right));
  });
}
