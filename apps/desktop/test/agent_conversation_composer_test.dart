import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('image paste consumes the native text paste action', (
    tester,
  ) async {
    var imagePasteCount = 0;
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
          onPasteImage: () async {
            imagePasteCount += 1;
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(imagePasteCount, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
  });

  testWidgets('non-image paste delegates to Flutter text paste', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': 'pasted text'};
      }
      if (call.method == 'Clipboard.hasStrings') {
        return <String, dynamic>{'value': true};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
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
          onPasteImage: () async => false,
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'pasted text',
    );
  });

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

  testWidgets('attachments open the empty-text submission port', (
    tester,
  ) async {
    final submissions = <String>[];
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
          initialDraft: '',
          hasAttachments: true,
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
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    expect(submissions, ['']);
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

  testWidgets('group composer opens and filters the @ mention member list', (
    tester,
  ) async {
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Group',
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
          mentionTargets: [_target('codex', 'Codex'), _target('kimi', 'Kimi')],
          mentionLabels: const {'codex': 'Codex', 'kimi': 'Kimi'},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();
    expect(
      find.byKey(const Key('agent-conversation-mention-suggestions')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-conversation-mention-codex')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-conversation-mention-kimi')),
      findsOneWidget,
    );
    final selectedRow = tester.widget<Material>(
      find.byKey(const Key('agent-conversation-mention-surface-codex')),
    );
    expect(selectedRow.color, Colors.white.withAlpha(24));
    expect(selectedRow.color, isNot(contextPrimaryColor(tester)));

    await tester.enterText(find.byType(TextField), '@ki');
    await tester.pump();
    expect(
      find.byKey(const Key('agent-conversation-mention-codex')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('agent-conversation-mention-kimi')),
      findsOneWidget,
    );
  });

  testWidgets('mention click inserts the exact structured dispatch alias', (
    tester,
  ) async {
    String draft = '';
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Group',
          initialDraft: '',
          busy: false,
          enabled: true,
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
          onDraftChanged: (value) => draft = value,
          onSend: (_) async => true,
          mentionTargets: [_target('claude-code', 'Claude Code')],
          mentionLabels: const {'claude-code': 'Claude Code'},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'ask @cla');
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('agent-conversation-mention-claude-code')),
    );
    await tester.pump();

    expect(draft, 'ask @Claude Code ');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'ask @Claude Code ',
    );
    expect(
      find.byKey(const Key('agent-conversation-mention-suggestions')),
      findsNothing,
    );
  });

  testWidgets('mention keyboard selection inserts the highlighted member', (
    tester,
  ) async {
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Group',
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
          mentionTargets: [_target('codex', 'Codex'), _target('kimi', 'Kimi')],
          mentionLabels: const {'codex': 'Codex', 'kimi': 'Kimi'},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '@Kimi ',
    );
  });

  testWidgets('mention keyboard navigation keeps selection visible', (
    tester,
  ) async {
    final targets = [
      for (var index = 0; index < 7; index += 1)
        _target('agent-$index', 'Agent $index'),
    ];
    await tester.pumpWidget(
      _ComposerTestApp(
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Group',
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
          mentionTargets: targets,
          mentionLabels: {
            for (var index = 0; index < 7; index += 1)
              'agent-$index': 'Agent $index',
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();
    for (var index = 0; index < 6; index += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }

    final listRect = tester.getRect(
      find.byKey(const Key('agent-conversation-mention-list')),
    );
    final selectedRect = tester.getRect(
      find.byKey(const Key('agent-conversation-mention-agent-6')),
    );
    expect(selectedRect.top, greaterThanOrEqualTo(listRect.top));
    expect(selectedRect.bottom, lessThanOrEqualTo(listRect.bottom));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final firstRect = tester.getRect(
      find.byKey(const Key('agent-conversation-mention-agent-0')),
    );
    expect(firstRect.top, greaterThanOrEqualTo(listRect.top));
    expect(firstRect.bottom, lessThanOrEqualTo(listRect.bottom));
  });

  testWidgets('single composer without members never opens mention list', (
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

    await tester.enterText(find.byType(TextField), '@');
    await tester.pump();
    expect(
      find.byKey(const Key('agent-conversation-mention-suggestions')),
      findsNothing,
    );
  });
}

Color contextPrimaryColor(WidgetTester tester) => Theme.of(
  tester.element(find.byKey(const Key('agent-conversation-mention-codex'))),
).colorScheme.primary;

TargetCandidate _target(String id, String label) => TargetCandidate(
  id: id,
  target: id,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/synthetic/bin/$id',
  adapterStatus: 'implemented',
  adapterCapabilities: const {'conversationDriver': 'implemented'},
);

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
