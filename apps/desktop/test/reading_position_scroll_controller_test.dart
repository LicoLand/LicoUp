import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/reading_position_scroll_controller.dart';

void main() {
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
    await tester.pumpWidget(
      _ReverseTranscript(controller: controller, itemCount: itemCount),
    );
    await tester.pump();

    expect(controller.offset, greaterThan(parked));
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
  const _ReverseTranscript({required this.controller, required this.itemCount});

  final ScrollController controller;
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView.builder(
          controller: controller,
          reverse: true,
          itemCount: itemCount,
          itemBuilder: (context, index) {
            return SizedBox(height: 48, child: Text('row-$index'));
          },
        ),
      ),
    );
  }
}
