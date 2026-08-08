import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/composer_agent_mention.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  test('parseComposerAgentMentionIds matches longest labels first', () {
    final ids = parseComposerAgentMentionIds(
      text: 'please ask @GitHub Copilot and @Codex',
      agents: const [
        (id: 'codex', label: 'Codex'),
        (id: 'copilot', label: 'GitHub Copilot'),
      ],
    );
    expect(ids, ['copilot', 'codex']);
  });

  testWidgets('buildComposerFlywheelMentionSections groups configured roles', (
    tester,
  ) async {
    late LicoStrings strings;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) {
            strings = LicoStrings.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final sections = buildComposerFlywheelMentionSections(
      policy: const AgentOrchestrationPolicy(
        commanderAgentId: 'antigravity',
        dailyConversationAgents: [
          DailyConversationAgentAssignment(agentId: 'antigravity'),
          DailyConversationAgentAssignment(agentId: 'codex'),
        ],
        designerAgents: [
          DailyConversationAgentAssignment(agentId: 'claude-code'),
        ],
      ),
      scannedTargets: [
        _target('antigravity', 'Antigravity'),
        _target('codex', 'Codex'),
        _target('claude-code', 'Claude Code'),
      ],
      strings: strings,
    );
    expect(sections.map((section) => section.id), [
      'daily-conversation',
      'designer',
    ]);
    expect(sections.first.entries.map((entry) => entry.agentId), [
      'antigravity',
      'codex',
    ]);
  });

  testWidgets('flywheel mention panel inserts chip and token into composer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bridge = ComposerMentionBridge();
    final antigravity = _target('antigravity', 'Antigravity');
    final sections = [
      ComposerFlywheelMentionSection(
        id: 'daily-conversation',
        title: '日常对话',
        entries: [
          ComposerFlywheelMentionEntry(
            agentId: 'antigravity',
            displayLabel: 'Antigravity',
            target: antigravity,
          ),
          ComposerFlywheelMentionEntry(
            agentId: 'codex',
            displayLabel: 'Codex',
            target: _target('codex', 'Codex'),
          ),
        ],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ComposerFlywheelCapsule(
                  mainAgentLabel: 'Antigravity',
                  mainAgentTarget: antigravity,
                  mentionSections: sections,
                  onEdit: () {},
                  onMentionAgent: (entry) => bridge.insertMention(
                    agentId: entry.agentId,
                    displayLabel: entry.displayLabel,
                    target: entry.target,
                  ),
                ),
                SizedBox(
                  width: 480,
                  child: RuntimeMessageComposer(
                    targetLabel: 'Lico',
                    initialDraft: 'hello',
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
                    mentionBridge: bridge,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('conversation-flywheel-button'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('提及角色与智能体'), findsOneWidget);
    expect(find.text('日常对话'), findsOneWidget);
    expect(find.text('模型'), findsNothing);

    await tester.tap(
      find.byKey(const Key('conversation-flywheel-mention-codex')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('composer-agent-mention-codex')),
      findsOneWidget,
    );
    expect(find.text('@Codex'), findsWidgets);
    expect(find.textContaining('@Codex'), findsWidgets);
  });
}

TargetCandidate _target(String id, String label) {
  return TargetCandidate(
    target: id,
    label: label,
    kind: 'native-history',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
  );
}
