import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets(
    'adaptive flywheel shows shared Designer and lane-specific Worker and Reviewer roles',
    (tester) async {
      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [_codexTarget()];
      AgentOrchestrationPolicy? result;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  result = await showDialog<AgentOrchestrationPolicy>(
                    context: context,
                    builder: (context) =>
                        AgentOrchestrationPolicyDialog(controller: controller),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('适应性飞轮'), findsOneWidget);
      expect(find.text('日常对话'), findsOneWidget);
      expect(
        find.byKey(const Key('agent-orchestration-daily-conversation-add')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('agent-orchestration-daily-conversation-add')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('agent-orchestration-daily-conversation-input')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('agent-orchestration-daily-conversation-options')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('agent-orchestration-daily-conversation-agent-card'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('agent-orchestration-daily-conversation-model-card'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('agent-orchestration-daily-conversation-settings-card'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('agent-orchestration-daily-conversation-option-codex'),
        ),
        findsOneWidget,
      );
      expect(find.text('智能体'), findsWidgets);
      expect(find.text('模型'), findsWidgets);
      expect(find.text('思考强度'), findsWidgets);
      expect(find.text('Fast'), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(
                  const Key('agent-orchestration-daily-conversation-input'),
                ),
                matching: find.byType(EditableText),
              ),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );

      await tester.tap(
        find.byKey(
          const Key('agent-orchestration-daily-conversation-option-codex'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_dailyConversationChips(), findsNothing);
      expect(
        find.byKey(const Key('agent-orchestration-daily-conversation-confirm')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('agent-orchestration-daily-conversation-confirm')),
      );
      await tester.pumpAndSettle();
      expect(_dailyConversationChips(), findsOneWidget);
      expect(
        find.byKey(const Key('agent-orchestration-daily-conversation-add')),
        findsOneWidget,
      );

      // Capsule body is not a remove control — only the trailing close is.
      await tester.tap(_dailyConversationChips().first);
      await tester.pumpAndSettle();
      expect(_dailyConversationChips(), findsOneWidget);
      await tester.tap(_dailyConversationChipRemoves().first);
      await tester.pumpAndSettle();
      expect(_dailyConversationChips(), findsNothing);

      // Confirm twice — multiple capsules for the same agent are allowed.
      for (var i = 0; i < 2; i++) {
        await tester.tap(
          find.byKey(const Key('agent-orchestration-daily-conversation-add')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const Key('agent-orchestration-daily-conversation-option-codex'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const Key('agent-orchestration-daily-conversation-confirm'),
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(_dailyConversationChips(), findsNWidgets(2));
      expect(find.text('主智能体'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('代码工程'),
        80,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('main-agent-settings')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('代码工程'), findsOneWidget);
      expect(find.text('Designer'), findsOneWidget);
      expect(find.text('Worker'), findsOneWidget);
      expect(find.text('Reviewer'), findsOneWidget);
      expect(find.text('后端线'), findsNWidgets(2));
      expect(find.text('前端线'), findsNWidgets(2));
      for (final role in CodeEngineeringRoleSlot.values) {
        expect(
          find.byKey(Key('agent-orchestration-code-${role.configKey}-agent')),
          findsOneWidget,
        );
      }

      await tester.tap(find.byKey(const Key('main-agent-save')));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.dailyConversationAgentIds, ['codex']);
      expect(result!.dailyConversationAgents, hasLength(2));
      expect(
        result!.dailyConversationAgents.every(
          (assignment) => assignment.modelName == 'gpt-5',
        ),
        isTrue,
      );
      expect(
        result!.dailyConversationAgents
            .map((assignment) => assignment.id)
            .toSet(),
        hasLength(2),
      );
      // First Daily Conversation capsule is the dispatch / main-agent owner.
      expect(result!.commanderAgentId, 'codex');
      expect(result!.commanderModelName, 'gpt-5');
      expect(result!.codeEngineeringConfigured, isTrue);
    },
  );
}

Finder _dailyConversationChips() {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    if (key is! ValueKey<String>) return false;
    final value = key.value;
    return value.startsWith('agent-orchestration-daily-conversation-chip-') &&
        !value.contains('-chip-remove-');
  });
}

Finder _dailyConversationChipRemoves() {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    if (key is! ValueKey<String>) return false;
    return key.value.startsWith(
      'agent-orchestration-daily-conversation-chip-remove-',
    );
  });
}

TargetCandidate _codexTarget() {
  return TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: '/synthetic/bin/codex',
    adapterStatus: 'implemented',
    adapterCapabilities: const {'conversationDriver': 'implemented'},
    modelCatalog: const {
      'models': [
        {
          'name': 'gpt-5',
          'displayName': 'GPT-5',
          'reasoningEfforts': ['medium', 'high'],
        },
      ],
    },
  );
}
