import 'package:flutter/material.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('renders and persists orchestration controls', (tester) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationReadiness': 'ready',
        },
        supportedActions: const ['runtime.message.send'],
        modelCatalog: const {
          'status': 'available',
          'models': [
            {'name': 'gpt-5.5', 'displayName': 'GPT-5.5'},
            {'name': 'gpt-5.4', 'displayName': 'GPT-5.4'},
          ],
        },
      ),
      TargetCandidate(
        target: 'claude-code',
        label: 'Claude Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.72,
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationReadiness': 'ready',
        },
        supportedActions: const ['runtime.message.send'],
        modelCatalog: const {
          'status': 'available',
          'models': [
            {
              'providerId': 'deepseek',
              'provider': 'DeepSeek',
              'name': 'deepseek-v4-flash',
              'reasoningEfforts': ['thinking-fast', 'thinking-deep'],
            },
            {
              'providerId': 'deepseek',
              'provider': 'DeepSeek',
              'name': 'deepseek-v4-pro',
              'reasoningEfforts': ['thinking-fast', 'thinking-deep'],
            },
          ],
        },
      ),
    ];
    await controller.selectConversationAgent(agentOrchestrationTargetId);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 980,
            height: 560,
            child: AgentConversationWorkspace(
              controller: controller,
              targets: controller.scannedTargets,
              scanning: false,
              adding: false,
              onAddTarget: () {},
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    Finder sendButtonFinder() {
      final keyed = find.byKey(const Key('agent-conversation-composer-send'));
      if (keyed.evaluate().isNotEmpty) {
        return keyed;
      }
      return find.byTooltip('Send');
    }

    bool composerInteractive() =>
        tester.widget<TextField>(find.byType(TextField)).enabled ?? false;

    expect(find.text('Default'), findsWidgets);
    expect(
      find.byKey(const Key('agent-orchestration-policy-select')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-policy-edit')),
      findsOneWidget,
    );
    expect(find.text('Configure a policy first'), findsWidgets);
    expect(composerInteractive(), isFalse);

    await tester.tap(find.byKey(const Key('agent-orchestration-policy-edit')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('agent-orchestration-policy-rule-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-dialog-policy-select')),
      findsOneWidget,
    );
    expect(find.text('Default Policy'), findsWidgets);
    expect(find.text('Commander'), findsOneWidget);
    expect(find.text('Model Library'), findsOneWidget);
    expect(
      find.byKey(const Key('agent-orchestration-commander-agent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-commander-model')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-commander-reasoning')),
      findsOneWidget,
    );
    expect(find.text('Claude Code'), findsWidgets);
    expect(find.text('deepseek-v4-flash'), findsWidgets);
    expect(
      find.byKey(const Key('agent-orchestration-model-library')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-model-library-agent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-model-library-model')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-orchestration-model-library-reasoning')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('agent-orchestration-model-library-add')),
    );
    await tester.pump();
    expect(
      find.byKey(
        const Key(
          'agent-orchestration-model-library-claude-code-deepseek-v4-flash-thinking-fast',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'agent-orchestration-model-library-claude-code-deepseek-v4-flash-low',
        ),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const Key('agent-orchestration-policy-rename')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-orchestration-policy-name-field')),
      'Review Policy',
    );
    await tester.tap(
      find.byKey(const Key('agent-orchestration-policy-rename-save')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Review Policy'), findsWidgets);

    await tester.tap(find.byKey(const Key('agent-orchestration-save-policy')));
    await tester.pumpAndSettle();

    expect(controller.agentOrchestrationPolicyConfigured, isTrue);
    expect(controller.agentOrchestrationPolicy.label, 'Review Policy');
    expect(controller.agentOrchestrationPolicy.commanderAgentId, 'claude-code');
    expect(
      controller.agentOrchestrationPolicy.commanderModelName,
      'deepseek-v4-flash',
    );
    expect(
      controller.agentOrchestrationPolicy.commanderReasoningEffort,
      'thinking-fast',
    );
    expect(controller.agentOrchestrationPolicy.modelLibrary, hasLength(1));
    expect(
      controller.agentOrchestrationPolicy.modelLibrary.map(
        (entry) => entry.key,
      ),
      containsAll([
        const AgentModelLibraryEntry(
          agentId: 'claude-code',
          modelName: 'deepseek-v4-flash',
          reasoningEffort: 'thinking-fast',
        ).key,
      ]),
    );
    expect(find.text('Review Policy'), findsWidgets);
    expect(find.text('Message Default'), findsOneWidget);
    expect(composerInteractive(), isTrue);
    await tester.enterText(find.byType(TextField), 'Route this task');
    await tester.pump();
    final sendInkWell = tester.widget<InkWell>(sendButtonFinder());
    expect(sendInkWell.onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
