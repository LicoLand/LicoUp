import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('composer owns draft lifecycle and emits trimmed submissions', (
    tester,
  ) async {
    final drafts = <String>[];
    final submissions = <String>[];

    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
          initialDraft: '',
          busy: false,
          enabled: true,
          disabledHint: '',
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: drafts.add,
          onSend: submissions.add,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '  fixture request  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();

    expect(drafts, contains('  fixture request  '));
    expect(submissions, ['fixture request']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
  });

  testWidgets('disabled composer closes input and submit ports', (
    tester,
  ) async {
    final submissions = <String>[];
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
          initialDraft: 'queued fixture',
          busy: false,
          enabled: false,
          disabledHint: 'Unavailable',
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (_) {},
          onSend: submissions.add,
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    expect(submissions, isEmpty);
  });

  testWidgets('busy composer keeps the follow-up queue submission port open', (
    tester,
  ) async {
    final submissions = <String>[];
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
          initialDraft: 'queued follow-up',
          busy: true,
          enabled: true,
          disabledHint: '',
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (_) {},
          onSend: submissions.add,
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    expect(submissions, ['queued follow-up']);
  });
}

class _ComposerTestApp extends StatelessWidget {
  const _ComposerTestApp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(body: child),
    );
  }
}
