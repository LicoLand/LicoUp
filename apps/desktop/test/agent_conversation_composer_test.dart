import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/features/agents/ui/composer_agent_mention.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
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
    // The running pulse lives on the header divider, never on the composer.
    expect(
      find.byKey(const Key('agent-conversation-composer-running-edge')),
      findsNothing,
    );
    expect(find.byKey(const Key('lico-top-edge-pulse-paint')), findsNothing);
    expect(find.byKey(const Key('lico-perimeter-pulse-paint')), findsNothing);
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    expect(submissions, ['queued follow-up']);
  });

  testWidgets('idle composer shows no running pulse on the top edge', (
    tester,
  ) async {
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
          onDraftChanged: (_) {},
          onSend: (_) async => true,
        ),
      ),
    );

    expect(find.byKey(const Key('lico-top-edge-pulse-paint')), findsNothing);
    expect(find.byKey(const Key('lico-perimeter-pulse-paint')), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion composer renders no execution edge line', (
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

    expect(find.byKey(const Key('lico-top-edge-pulse-paint')), findsNothing);
    expect(find.byKey(const Key('lico-perimeter-pulse-paint')), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('send button quiets after a successful send with mention chips', (
    tester,
  ) async {
    final submissions = <String>[];
    final bridge = ComposerMentionBridge();
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
          onDraftChanged: (_) {},
          onSend: (text) async {
            submissions.add(text);
            return true;
          },
          mentionBridge: bridge,
        ),
      ),
    );

    final sendButton = find.byKey(
      const Key('agent-conversation-composer-send'),
    );

    // Mention-only draft: the chip alone holds the sendable state.
    bridge.insertMention(agentId: 'codex', displayLabel: 'Codex');
    await tester.pump();
    expect(tester.widget<LicoIconButton>(sendButton).onPressed, isNotNull);

    await tester.tap(sendButton);
    await tester.pump();

    expect(submissions, ['@Codex']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
    // Regression: after a successful send the cleared text and chips must
    // quiet the send button instead of leaving it enabled-but-dead.
    expect(tester.widget<LicoIconButton>(sendButton).onPressed, isNull);

    // Typing again re-enables sending.
    await tester.enterText(find.byType(TextField), 'next message');
    await tester.pump();
    expect(tester.widget<LicoIconButton>(sendButton).onPressed, isNotNull);
    await tester.tap(sendButton);
    await tester.pump();
    expect(submissions, ['@Codex', 'next message']);
  });

  testWidgets('removing the last mention chip quiets the send button', (
    tester,
  ) async {
    final submissions = <String>[];
    final bridge = ComposerMentionBridge();
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
          onDraftChanged: (_) {},
          onSend: (text) async {
            submissions.add(text);
            return true;
          },
          mentionBridge: bridge,
        ),
      ),
    );

    final sendButton = find.byKey(
      const Key('agent-conversation-composer-send'),
    );
    bridge.insertMention(agentId: 'codex', displayLabel: 'Codex');
    await tester.pump();
    expect(tester.widget<LicoIconButton>(sendButton).onPressed, isNotNull);

    await tester.tap(
      find.byKey(const Key('composer-agent-mention-codex')),
    );
    await tester.pump();

    // Removing the only chip empties the draft and quiets the button.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
    expect(tester.widget<LicoIconButton>(sendButton).onPressed, isNull);
    await tester.tap(sendButton);
    await tester.pump();
    expect(submissions, isEmpty);
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

  testWidgets('composer embeds the runtime settings bar by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
          initialDraft: '',
          busy: false,
          enabled: true,
          modelOptions: const ['fixture-model'],
          selectedModel: 'fixture-model',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (_) {},
          onSend: (_) async => true,
        ),
      ),
    );

    expect(find.byType(ConversationRuntimeSettingsBar), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('showRuntimeSettings false hides the runtime settings bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
          initialDraft: '',
          busy: false,
          enabled: true,
          modelOptions: const ['fixture-model'],
          selectedModel: 'fixture-model',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (_) {},
          onSend: (_) async => true,
          showRuntimeSettings: false,
        ),
      ),
    );

    expect(find.byType(ConversationRuntimeSettingsBar), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('floating matte composer shows external attach capsule', (
    tester,
  ) async {
    var attachTapped = false;
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
          onDraftChanged: (_) {},
          onSend: (_) async => true,
          floatingMatteCapsule: true,
          onAttach: () => attachTapped = true,
        ),
      ),
    );

    expect(
      find.byKey(const Key('agent-conversation-composer-attach')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('agent-conversation-composer-attach')),
    );
    await tester.pump();
    expect(attachTapped, isTrue);
  });

  testWidgets('non-floating composer hides external attach capsule', (
    tester,
  ) async {
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
          onDraftChanged: (_) {},
          onSend: (_) async => true,
          onAttach: () {},
        ),
      ),
    );

    expect(
      find.byKey(const Key('agent-conversation-composer-attach')),
      findsNothing,
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
