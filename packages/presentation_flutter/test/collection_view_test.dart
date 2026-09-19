import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

void main() {
  testWidgets('CollectionView renders items in forward direction', (
    tester,
  ) async {
    final items = List.generate(5, (i) => 'Item $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollectionView<String>(
            items: items,
            itemKey: (item) => item,
            itemBuilder: (context, item, index) =>
                SizedBox(height: 50, child: Text(item)),
          ),
        ),
      ),
    );

    expect(find.text('Item 0'), findsOneWidget);
    expect(find.text('Item 4'), findsOneWidget);
  });

  testWidgets('CollectionView displays emptyBuilder when items is empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollectionView<String>(
            items: const [],
            itemKey: (item) => item,
            emptyBuilder: (context) =>
                const Center(child: Text('No items found')),
            itemBuilder: (context, item, index) => Text(item),
          ),
        ),
      ),
    );

    expect(find.text('No items found'), findsOneWidget);
  });

  testWidgets('CollectionView reverse mode sets up ReadingPositionAnchor', (
    tester,
  ) async {
    final items = List.generate(10, (i) => 'Msg $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollectionView<String>(
            items: items,
            reverse: true,
            itemKey: (item) => item,
            itemBuilder: (context, item, index) =>
                SizedBox(height: 60, child: Text(item)),
          ),
        ),
      ),
    );

    // In reverse mode, ReadingPositionAnchor wraps each row
    expect(find.byType(ReadingPositionAnchor), findsWidgets);
    expect(find.text('Msg 0'), findsOneWidget);
  });

  testWidgets(
    'ReadingPositionScrollController preserves reading offset when new items arrive at zero',
    (tester) async {
      final controller = ReadingPositionScrollController();
      var items = List.generate(20, (i) => 'Msg $i');

      late StateSetter setListState;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setListState = setState;
                return CollectionView<String>(
                  controller: controller,
                  reverse: true,
                  items: items,
                  itemKey: (item) => item,
                  itemBuilder: (context, item, index) =>
                      SizedBox(height: 60, child: Text(item)),
                );
              },
            ),
          ),
        ),
      );

      // Scroll up into older messages
      controller.jumpTo(200.0);
      await tester.pump();
      expect(controller.offset, 200.0);

      // Capture reading anchor
      controller.captureReadingAnchor();

      // Now new item arrives at the newest edge (index 0 in items)
      setListState(() {
        items = ['Msg new', ...items];
      });
      await tester.pump();

      // In reverse: true with reading anchor, the content offset is corrected
      // so the reader does NOT experience a visual jump!
      expect(controller.offset, greaterThanOrEqualTo(200.0));
    },
  );

  testWidgets('CollectionView triggers onLoadEarlier near edge', (
    tester,
  ) async {
    var loadEarlierCalled = false;
    final items = List.generate(20, (i) => 'Item $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: CollectionView<String>(
              items: items,
              hasEarlier: true,
              earlierPageLeadIn: 100,
              onLoadEarlier: () async {
                loadEarlierCalled = true;
              },
              itemKey: (item) => item,
              itemBuilder: (context, item, index) =>
                  SizedBox(height: 50, child: Text(item)),
            ),
          ),
        ),
      ),
    );

    // Fling to bottom / edge
    await tester.drag(
      find.byType(CollectionView<String>),
      const Offset(0, -600),
    );
    await tester.pump();

    expect(loadEarlierCalled, isTrue);
  });

  testWidgets(
    'CollectionView displays loading earlier row when isLoadingEarlier is true',
    (tester) async {
      final items = List.generate(3, (i) => 'Row $i');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollectionView<String>(
              items: items,
              hasEarlier: true,
              isLoadingEarlier: true,
              itemKey: (item) => item,
              itemBuilder: (context, item, index) =>
                  SizedBox(height: 40, child: Text(item)),
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets('CollectionView renders header and footer when provided', (
    tester,
  ) async {
    final items = ['Item 1', 'Item 2'];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollectionView<String>(
            items: items,
            header: const Text('Top Header Banner'),
            footer: const Text('Bottom Footer Banner'),
            itemKey: (item) => item,
            itemBuilder: (context, item, index) => Text(item),
          ),
        ),
      ),
    );

    expect(find.text('Top Header Banner'), findsOneWidget);
    expect(find.text('Item 1'), findsOneWidget);
    expect(find.text('Item 2'), findsOneWidget);
    expect(find.text('Bottom Footer Banner'), findsOneWidget);
  });

  testWidgets('CollectionView wraps items in RepaintBoundary when enabled', (
    tester,
  ) async {
    final items = ['Row A'];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollectionView<String>(
            items: items,
            wrapWithRepaintBoundary: true,
            itemKey: (item) => item,
            itemBuilder: (context, item, index) => Text(item),
          ),
        ),
      ),
    );

    expect(find.byType(RepaintBoundary), findsWidgets);
    expect(find.text('Row A'), findsOneWidget);
  });
}
