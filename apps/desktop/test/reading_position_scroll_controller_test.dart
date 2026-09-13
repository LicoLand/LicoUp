import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/reading_position_scroll_controller.dart';

void main() {
  testWidgets(
    'a replacement scroll position cannot consume the previous transcript anchor',
    (tester) async {
      final controller = ReadingPositionScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _ReverseTranscript(controller: controller, itemCount: 20),
      );
      controller.jumpTo(240);
      await tester.pumpAndSettle();
      final previous = controller.position;
      controller.captureReadingAnchor();

      await tester.pumpWidget(
        _ReverseTranscript(
          controller: controller,
          itemCount: 10,
          identity: 'child',
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(controller.position, isNot(same(previous)));
      expect(controller.position.hasContentDimensions, isTrue);
      expect(controller.offset, 0);
    },
  );

  testWidgets(
    'another viewport layout does not clear the captured position anchor',
    (tester) async {
      final controller = ReadingPositionScrollController();
      addTearDown(controller.dispose);
      Widget view({required bool addSecond, required int itemCount}) =>
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    key: const ValueKey('second'),
                    height: 250,
                    child: addSecond
                        ? _reverseList(controller, 10, 'second')
                        : null,
                  ),
                  SizedBox(
                    key: const ValueKey('first'),
                    height: 250,
                    child: _reverseList(controller, itemCount, 'first'),
                  ),
                ],
              ),
            ),
          );
      await tester.pumpWidget(view(addSecond: false, itemCount: 20));
      controller.jumpTo(240);
      await tester.pumpAndSettle();
      final captured = controller.position;
      controller.captureReadingAnchor();
      await tester.pumpWidget(view(addSecond: true, itemCount: 28));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(controller.positions, hasLength(2));
      expect(captured.pixels, closeTo(240 + 8 * 48, 1));
      final added = controller.positions.singleWhere(
        (value) => !identical(value, captured),
      );
      expect(added.pixels, 0);
    },
  );

  testWidgets('holds reading position when idle and content grows at newest', (
    tester,
  ) async {
    final controller = ReadingPositionScrollController();
    addTearDown(controller.dispose);
    var itemCount = 20;
    await tester.pumpWidget(
      _ReverseTranscript(controller: controller, itemCount: itemCount),
    );

    await tester.drag(find.byType(ListView), const Offset(0, 280));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(48));
    final parked = controller.offset;

    itemCount = 28;
    controller.captureReadingAnchor();
    await tester.pumpWidget(
      _ReverseTranscript(controller: controller, itemCount: itemCount),
    );
    await tester.pump();

    expect(controller.offset, closeTo(parked + 8 * 48, 1));
  });

  testWidgets('does not correct pixels while the user is dragging', (
    tester,
  ) async {
    final controller = ReadingPositionScrollController();
    addTearDown(controller.dispose);
    var itemCount = 20;
    await tester.pumpWidget(
      _ReverseTranscript(controller: controller, itemCount: itemCount),
    );

    await tester.drag(find.byType(ListView), const Offset(0, 280));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(48));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    final whileDragging = controller.offset;

    itemCount = 28;
    controller.captureReadingAnchor();
    await tester.pumpWidget(
      _ReverseTranscript(controller: controller, itemCount: itemCount),
    );
    await tester.pump();

    expect((controller.offset - whileDragging).abs(), lessThan(80));

    await gesture.up();
    await tester.pumpAndSettle();
  });
}

class _ReverseTranscript extends StatelessWidget {
  const _ReverseTranscript({
    required this.controller,
    required this.itemCount,
    this.identity = 'root',
  });

  final ScrollController controller;
  final int itemCount;
  final String identity;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(body: _reverseList(controller, itemCount, identity)),
    );
  }
}

Widget _reverseList(
  ScrollController controller,
  int itemCount,
  String identity,
) => ListView.builder(
  key: PageStorageKey(identity),
  controller: controller,
  reverse: true,
  itemCount: itemCount,
  itemBuilder: (context, index) {
    final row = itemCount - 1 - index;
    return ReadingPositionAnchor(
      key: ValueKey(row),
      controller: controller,
      anchorId: (identity, row),
      isRow: true,
      child: SizedBox(height: 48, child: Text('row-$row')),
    );
  },
);
