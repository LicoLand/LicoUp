import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: drafts.add,
          onSend: (text) async {
            submissions.add(text);
            return true;
          },
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
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (_) {},
          onSend: (text) async {
            submissions.add(text);
            return true;
          },
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
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (_) {},
          onSend: (text) async {
            submissions.add(text);
            return true;
          },
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    final pulse = tester.widget<LicoPerimeterPulse>(
      find.byKey(const Key('agent-conversation-composer-running-border')),
    );
    expect(pulse.enabled, isTrue);
    expect(find.byKey(const Key('lico-perimeter-pulse-paint')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    expect(submissions, ['queued follow-up']);
  });

  testWidgets('reduced motion keeps a static execution outline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _ComposerTestApp(
        reducedMotion: true,
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
          initialDraft: '',
          busy: true,
          enabled: true,
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (_) {},
          onSend: (_) async => true,
        ),
      ),
    );

    expect(find.byKey(const Key('lico-perimeter-pulse-paint')), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('composer restores a submission rejected before execution', (
    tester,
  ) async {
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
          initialDraft: 'retry this request',
          busy: false,
          enabled: true,
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (_) {},
          onSend: (_) async => false,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'retry this request',
    );
  });
}

class _ComposerTestApp extends StatelessWidget {
  const _ComposerTestApp({required this.child, this.reducedMotion = false});

  final Widget child;
  final bool reducedMotion;

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
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: child!,
      ),
      home: Scaffold(body: child),
    );
  }
}
