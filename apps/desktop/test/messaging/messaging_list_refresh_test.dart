import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/messaging/messaging_list_refresh.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  for (final count in [0, 1, 60]) {
    testWidgets('a $count-row catalog refreshes once and springs back', (
      tester,
    ) async {
      final loading = ValueNotifier(false);
      addTearDown(loading.dispose);
      var refreshes = 0;
      await _pumpList(
        tester,
        count: count,
        loading: loading,
        onRefresh: () {
          refreshes += 1;
          loading.value = true;
        },
      );
      final list = find.byType(ListView);
      final position = _position(tester);

      await tester.drag(list, const Offset(0, 45));
      await tester.pumpAndSettle();
      expect(refreshes, 0);
      expect(position.pixels, 0);

      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, 220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(position.pixels, lessThan(-80));
      expect(refreshes, 0, reason: 'holding an armed pull does not refresh');
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byKey(const Key('messaging-list-refresh-indicator')),
            )
            .value,
        1,
      );
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(refreshes, 1);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byKey(const Key('messaging-list-refresh-indicator')),
            )
            .value,
        isNull,
      );

      for (var frame = 0; frame < 80; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(position.pixels, 0, reason: 'loading does not pin overscroll');
      await tester.drag(list, const Offset(0, 220));
      for (var frame = 0; frame < 80; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(refreshes, 1, reason: 'an active refresh cannot be duplicated');

      loading.value = false;
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('messaging-list-refresh-indicator')),
        findsNothing,
      );
      expect(position.pixels, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('trackpad pull refreshes while wheel deltas stay native', (
    tester,
  ) async {
    var refreshes = 0;
    final loading = ValueNotifier(false);
    addTearDown(loading.dispose);
    await _pumpList(
      tester,
      count: 60,
      loading: loading,
      onRefresh: () => refreshes += 1,
    );
    final list = find.byType(ListView);
    await tester.trackpadFling(list, const Offset(0, 260), 900);
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(_position(tester).pixels, 0);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, 120);
    expect(refreshes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a no-op refresh leaves no pending state or stuck offset', (
    tester,
  ) async {
    var refreshes = 0;
    final loading = ValueNotifier(false);
    addTearDown(loading.dispose);
    await _pumpList(
      tester,
      count: 1,
      loading: loading,
      onRefresh: () => refreshes += 1,
    );
    for (var attempt = 1; attempt <= 2; attempt += 1) {
      await tester.drag(find.byType(ListView), const Offset(0, 220));
      await tester.pumpAndSettle();
      expect(refreshes, attempt);
      expect(_position(tester).pixels, 0);
      expect(
        find.byKey(const Key('messaging-list-refresh-indicator')),
        findsNothing,
      );
    }
  });

  testWidgets('returning an armed pull before release cancels refresh', (
    tester,
  ) async {
    var refreshes = 0;
    final loading = ValueNotifier(false);
    addTearDown(loading.dispose);
    await _pumpList(
      tester,
      count: 1,
      loading: loading,
      onRefresh: () => refreshes += 1,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -500));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    expect(_position(tester).pixels, 0);
  });

  testWidgets(
    'a synchronous refresh failure does not interrupt spring return',
    (tester) async {
      final loading = ValueNotifier(false);
      addTearDown(loading.dispose);
      await _pumpList(
        tester,
        count: 1,
        loading: loading,
        onRefresh: () => throw StateError('synthetic refresh failure'),
      );
      await tester.drag(find.byType(ListView), const Offset(0, 220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(tester.takeException(), isStateError);
      await tester.pumpAndSettle();
      expect(_position(tester).pixels, 0);
      expect(
        find.byKey(const Key('messaging-list-refresh-indicator')),
        findsNothing,
      );
    },
  );

  testWidgets('leaving during refresh releases the indicator ticker', (
    tester,
  ) async {
    final loading = ValueNotifier(true);
    addTearDown(loading.dispose);
    await _pumpList(tester, count: 1, loading: loading, onRefresh: () {});
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position;

Future<void> _pumpList(
  WidgetTester tester, {
  required int count,
  required ValueNotifier<bool> loading,
  required VoidCallback onRefresh,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLicoTheme(
        platformBrightness: Brightness.dark,
      ).copyWith(platform: TargetPlatform.macOS),
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 560,
          child: ValueListenableBuilder<bool>(
            valueListenable: loading,
            builder: (context, refreshing, _) => MessagingListRefresh(
              onRefresh: onRefresh,
              refreshing: refreshing,
              child: ListView.builder(
                physics: messagingListScrollPhysics,
                itemCount: count,
                itemBuilder: (_, index) =>
                    SizedBox(height: 64, child: Text('Conversation $index')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
