import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// The production composer is a controlled view: the owner keeps the draft and
/// publishes it back through the composer channel only. This harness models
/// that split, so the tests below observe the real contract instead of a
/// private text mirror.
void main() {
  testWidgets(
    'parent rebuilds and resource revisions keep the caret in place',
    (tester) async {
      await tester.pumpWidget(_owner());
      await tester.enterText(find.byType(TextField), 'alpha beta gamma');
      await tester.pump();
      _select(tester, 5);
      await tester.pump();

      final owner = _ownerState(tester);
      // Unrelated resources republish the composer channel with the same draft.
      owner.resources.value += 1;
      await tester.pump();
      expect(_text(tester), 'alpha beta gamma');
      expect(_selection(tester), const TextSelection.collapsed(offset: 5));

      // A theme change rebuilds the composer without touching the draft.
      await tester.pumpWidget(
        _owner(theme: buildLicoTheme(platformBrightness: Brightness.dark)),
      );
      await tester.pump();
      expect(_text(tester), 'alpha beta gamma');
      expect(_selection(tester), const TextSelection.collapsed(offset: 5));

      // An edit lands at the retained caret, not at the end of the text.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'alphaX beta gamma',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();
      expect(_text(tester), 'alphaX beta gamma');
      expect(_selection(tester), const TextSelection.collapsed(offset: 6));
    },
  );

  testWidgets('the owner echo of our own write never schedules another write', (
    tester,
  ) async {
    await tester.pumpWidget(_owner());
    final owner = _ownerState(tester);

    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump();
    expect(owner.writes, ['a']);

    // The owner echoed 'a' back. Rebuilding with that echo must not be read as
    // a new edit, and nothing may schedule a second store write.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    owner.resources.value += 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(owner.writes, ['a']);
    expect(_text(tester), 'a');

    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pump();
    expect(owner.writes, ['a', 'ab']);
  });

  testWidgets('draft changes rebuild only the regions that read the draft', (
    tester,
  ) async {
    await tester.pumpWidget(_owner());
    final owner = _ownerState(tester);
    final before = owner.unrelatedBuilds;

    for (final text in ['h', 'he', 'hel', 'hell', 'hello']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
    }
    owner.resources.value += 1;
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    await tester.pump();

    expect(owner.unrelatedBuilds, before);
  });

  testWidgets('send clears through the owner and follows the published draft', (
    tester,
  ) async {
    await tester.pumpWidget(_owner());
    final owner = _ownerState(tester);

    await tester.enterText(find.byType(TextField), '  fixture request  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    await tester.pump();

    expect(owner.submissions, ['fixture request']);
    expect(owner.writes.last, '');
    expect(_text(tester), '');
    expect(owner.draft.value, '');
  });

  testWidgets('a refused send restores the draft through the owner', (
    tester,
  ) async {
    await tester.pumpWidget(_owner(consumeSend: false));
    final owner = _ownerState(tester);

    await tester.enterText(find.byType(TextField), 'retry me');
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    await tester.pump();

    expect(owner.submissions, ['retry me']);
    expect(owner.draft.value, 'retry me');
    expect(_text(tester), 'retry me');
  });

  testWidgets(
    'rapid resource switching restores the owner draft, not a stale echo',
    (tester) async {
      await tester.pumpWidget(_owner());
      final owner = _ownerState(tester);

      await tester.enterText(find.byType(TextField), 'first draft');
      await tester.pump();

      for (final draft in ['second', 'third', 'fourth']) {
        owner.draft.value = draft;
        await tester.pump();
        expect(_text(tester), draft);
        expect(_selection(tester).extentOffset, draft.length);
        // The composer asked the owner for the restore; it did not write the
        // restored text back as an edit.
        expect(owner.writes.last, 'first draft');
      }
    },
  );

  testWidgets('a long multiline draft survives a resource revision', (
    tester,
  ) async {
    await tester.pumpWidget(_owner());
    final owner = _ownerState(tester);
    final long = List<String>.generate(
      40,
      (index) => 'Line $index of a long draft',
    ).join('\n');

    await tester.enterText(find.byType(TextField), long);
    await tester.pump();
    expect(owner.draft.value, long);

    _select(tester, long.length - 3);
    await tester.pump();
    owner.resources.value += 1;
    await tester.pump();

    expect(_text(tester), long);
    expect(
      _selection(tester),
      TextSelection.collapsed(offset: long.length - 3),
    );
  });

  testWidgets('an IME composition survives rebuilds and holds back submit', (
    tester,
  ) async {
    await tester.pumpWidget(_owner());
    final owner = _ownerState(tester);
    final field = find.byType(TextField);
    await tester.showKeyboard(field);
    await tester.pump();
    owner.writes.clear();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    expect(owner.writes, ['你好']);

    owner.resources.value += 1;
    await tester.pump();
    expect(
      _controller(tester).value.composing,
      const TextRange(start: 0, end: 2),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(owner.submissions, isEmpty);
    expect(_text(tester), '你好');

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(owner.submissions, ['你好']);
  });

  testWidgets('an attachment-only draft still submits and clears', (
    tester,
  ) async {
    await tester.pumpWidget(_owner(hasAttachments: true));
    final owner = _ownerState(tester);

    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    await tester.pump();

    expect(owner.submissions, ['']);
    expect(owner.writes.last, '');
  });
}

Widget _owner({
  bool hasAttachments = false,
  bool consumeSend = true,
  ThemeData? theme,
}) => MaterialApp(
  theme: theme ?? buildLicoTheme(platformBrightness: Brightness.light),
  home: Scaffold(
    body: _ComposerOwner(
      hasAttachments: hasAttachments,
      consumeSend: consumeSend,
    ),
  ),
);

_ComposerOwnerState _ownerState(WidgetTester tester) =>
    tester.state<_ComposerOwnerState>(find.byType(_ComposerOwner));

TextEditingController _controller(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!;

String _text(WidgetTester tester) => _controller(tester).text;

TextSelection _selection(WidgetTester tester) => _controller(tester).selection;

void _select(WidgetTester tester, int offset) {
  _controller(tester).selection = TextSelection.collapsed(offset: offset);
}

/// Production owner shape: the draft lives here, is published back as the
/// composer's value through the composer channel only, and unrelated regions
/// read a different channel.
final class _ComposerOwner extends StatefulWidget {
  const _ComposerOwner({
    required this.hasAttachments,
    required this.consumeSend,
  });

  final bool hasAttachments;
  final bool consumeSend;

  @override
  State<_ComposerOwner> createState() => _ComposerOwnerState();
}

final class _ComposerOwnerState extends State<_ComposerOwner> {
  final ValueNotifier<String> draft = ValueNotifier<String>('');
  final ValueNotifier<int> resources = ValueNotifier<int>(0);
  final List<String> writes = <String>[];
  final List<String> submissions = <String>[];
  int unrelatedBuilds = 0;

  void _onDraftChanged(String value) {
    writes.add(value);
    draft.value = value;
  }

  @override
  void dispose() {
    draft.dispose();
    resources.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ValueListenableBuilder<String>(
            valueListenable: draft,
            builder: (context, value, _) => ValueListenableBuilder<int>(
              valueListenable: resources,
              builder: (context, revision, _) => RuntimeMessageComposer(
                targetLabel: 'Fixture Agent',
                initialDraft: value,
                hasAttachments: widget.hasAttachments,
                busy: false,
                enabled: true,
                modelOptions: const [],
                selectedModel: '',
                reasoningEffortOptions: const [],
                selectedReasoningEffort: '',
                onModelChanged: (_) {},
                onReasoningEffortChanged: (_) {},
                onDraftChanged: _onDraftChanged,
                onSend: (text) async {
                  submissions.add(text);
                  return widget.consumeSend;
                },
              ),
            ),
          ),
        ),
        _BuildCounter(onBuild: () => unrelatedBuilds += 1),
      ],
    );
  }
}

/// A region that reads none of the composer channels. It must keep its element
/// and never rebuild for a draft write.
final class _BuildCounter extends StatelessWidget {
  const _BuildCounter({required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(height: 24, child: Text('unrelated region'));
  }
}
