import 'pane_test_harness.dart';

void main() {
  testWidgets(
    'resize handle reports drag deltas and collapsed split hides history',
    (tester) async {
      var dragged = 0.0;
      await tester.pumpWidget(
        paneTestApp(
          PaneEdgeDragHandle(
            dragHandleKey: const Key('test-pane-drag-handle'),
            width: 12,
            onDragDelta: (value) => dragged += value,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.drag(
        find.byKey(const Key('test-pane-drag-handle')),
        const Offset(32, 0),
      );
      expect(dragged, greaterThan(0));

      await tester.pumpWidget(
        paneTestApp(
          const ResizableConversationSplit(
            historyPane: SizedBox(key: Key('test-history-pane')),
            chatPane: SizedBox(key: Key('test-chat-pane')),
            initialHistoryWidth: 260,
            historyCollapsed: true,
          ),
        ),
      );
      expect(find.byKey(const Key('test-history-pane')), findsNothing);
      expect(find.byKey(const Key('test-chat-pane')), findsOneWidget);
    },
  );
}
