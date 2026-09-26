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

  testWidgets('controlled value echoes locally and reports editing changes', (
    tester,
  ) async {
    final reported = <TextEditingValue>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputField(
            value: const TextEditingValue(text: 'draft'),
            onValueChanged: reported.add,
          ),
        ),
      ),
    );

    expect(find.text('draft'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'drafted');
    await tester.pump();

    // Local echo is immediate, and the owner receives the full editing value.
    expect(find.text('drafted'), findsOneWidget);
    expect(reported.last.text, 'drafted');
  });

  testWidgets('unchanged controlled value never clobbers local echo', (
    tester,
  ) async {
    const value = TextEditingValue(text: 'business value');

    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return InputField(value: value, onValueChanged: (_) {});
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'typed locally');
    await tester.pump();

    // A rebuild that repeats the same value is not a business reset: the
    // keystroke stays visible and is never replaced by the stale value.
    rebuild(() {});
    await tester.pump();

    expect(find.text('typed locally'), findsOneWidget);
    expect(find.text('business value'), findsNothing);
  });

  testWidgets('a changed controlled value replaces the local text', (
    tester,
  ) async {
    var value = const TextEditingValue(text: 'first');
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return InputField(value: value, onValueChanged: (_) {});
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'local draft');
    await tester.pump();
    expect(find.text('local draft'), findsOneWidget);

    rebuild(() {
      value = const TextEditingValue(text: 'installed by owner');
    });
    await tester.pump();

    expect(find.text('installed by owner'), findsOneWidget);
    expect(find.text('local draft'), findsNothing);
  });

  testWidgets('a controlled field leaves clearing to its owner', (
    tester,
  ) async {
    var value = const TextEditingValue(text: 'send me');
    String? submitted;
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return InputField(
                value: value,
                onSubmit: (text) => submitted = text,
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(submitted, 'send me');
    // Local echo survives the submit until the owner decides the outcome.
    expect(find.text('send me'), findsOneWidget);

    rebuild(() {
      value = TextEditingValue.empty;
    });
    await tester.pump();

    expect(find.text('send me'), findsNothing);
  });

  testWidgets('duplicate submit paths do not send the same press twice', (
    tester,
  ) async {
    var submits = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputField(clearOnSubmit: false, onSubmit: (_) => submits++),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'only once');
    await tester.pump();

    // The key handler and the platform submit action can both fire for one
    // physical Enter; the field must dispatch a single business submit.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(submits, 1);
  });

  testWidgets('the platform submit action sends the message', (tester) async {
    String? submitted;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InputField(onSubmit: (text) => submitted = text)),
      ),
    );

    await tester.enterText(find.byType(TextField), 'from the send action');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(submitted, 'from the send action');
  });

  testWidgets('the platform send action sends the committed composition', (
    tester,
  ) async {
    var submits = 0;
    String? submitted;
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputField(
            controller: controller,
            onSubmit: (text) {
              submits++;
              submitted = text;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();

    // The IME is composing a candidate. The send action belongs to the key
    // handler path, which refuses to submit mid-composition.
    controller.value = const TextEditingValue(
      text: 'nihao',
      composing: TextRange(start: 0, end: 5),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submits, 0);

    // The platform commits the candidate, then the user sends.
    controller.value = const TextEditingValue(text: '你好');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(submits, 1);
    expect(submitted, '你好');
  });
}
