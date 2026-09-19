import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

void main() {
  testWidgets('InputField accepts text typing and fires onChanged', (
    tester,
  ) async {
    String changedValue = '';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputField(
            hintText: 'Type a message...',
            onChanged: (val) => changedValue = val,
          ),
        ),
      ),
    );

    expect(find.text('Type a message...'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Hello Agent');
    await tester.pump();

    expect(changedValue, 'Hello Agent');
    expect(find.text('Hello Agent'), findsOneWidget);
  });

  testWidgets('InputField Enter submits text and clears field by default', (
    tester,
  ) async {
    String submittedValue = '';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputField(onSubmit: (val) => submittedValue = val),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'Send this message');
    await tester.pump();

    // Press Enter
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(submittedValue, 'Send this message');
    // Field should be cleared after submit
    expect(find.text('Send this message'), findsNothing);
  });

  testWidgets('InputField ignores empty or whitespace-only submits', (
    tester,
  ) async {
    var submitCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InputField(onSubmit: (_) => submitCalled = true)),
      ),
    );

    await tester.enterText(find.byType(TextField), '    ');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(submitCalled, isFalse);
  });

  testWidgets('InputField preserves cursor position across parent rebuilds', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Initial text');
    // Place cursor between 'Initial' and ' text' (offset 7)
    controller.selection = const TextSelection.collapsed(offset: 7);

    late StateSetter setParentState;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setParentState = setState;
              return InputField(controller: controller);
            },
          ),
        ),
      ),
    );

    expect(controller.selection.baseOffset, 7);

    // Trigger unrelated parent rebuild
    setParentState(() {});
    await tester.pump();

    // Cursor position remains 100% preserved
    expect(controller.selection.baseOffset, 7);
  });

  testWidgets('InputField does not submit during active IME composition', (
    tester,
  ) async {
    var submitCalled = false;
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputField(
            controller: controller,
            onSubmit: (_) => submitCalled = true,
          ),
        ),
      ),
    );

    // Simulate IME composition (e.g. typing pinyin "nihao" before choosing hanzi)
    controller.value = const TextEditingValue(
      text: 'nihao',
      composing: TextRange(start: 0, end: 5),
    );
    await tester.pump();

    // User presses Enter to confirm IME candidate
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // IME composition candidate selection must NOT submit the message
    expect(submitCalled, isFalse);
  });

  testWidgets('InputField Escape key triggers onCancel', (tester) async {
    var cancelCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InputField(onCancel: () => cancelCalled = true)),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(cancelCalled, isTrue);
  });

  testWidgets('InputField disabled state prevents submission', (tester) async {
    var submitCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputField(
            enabled: false,
            onSubmit: (_) => submitCalled = true,
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(submitCalled, isFalse);
  });
}
