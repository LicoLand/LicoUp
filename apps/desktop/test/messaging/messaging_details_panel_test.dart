import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_details_panel.dart';

import '../agent_conversation_pane/pane_test_harness.dart';

void main() {
  testWidgets('popover variant renders compact scroll body', (tester) async {
    await tester.pumpWidget(
      paneTestApp(
        SizedBox(
          width: 340,
          height: 480,
          child: MessagingDetailsPanel(
            state: _panelState(),
            actions: paneTestActions(),
            forPopover: true,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('messaging-details-popover')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-details-panel-body')),
      findsOneWidget,
    );
    expect(find.text('Details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('details panel renders runtime, capabilities, and session', (
    tester,
  ) async {
    const session = AgentConversationSession(
      id: 'session-1',
      agentId: 'codex',
      title: 'Focused session',
      createdAt: '2026-07-16T08:30:00',
      updatedAt: '2026-07-16T09:00:00',
      messages: [],
      workingDirectory: '/work/project-alpha',
      messageCount: 5,
    );
    await tester.pumpWidget(
      paneTestApp(
        MessagingDetailsPanel(
          state: _panelState(session: session),
          actions: paneTestActions(),
        ),
      ),
    );

    expect(find.text('Details'), findsOneWidget);
    expect(find.text('RUNTIME'), findsOneWidget);
    expect(find.text('CAPABILITIES'), findsOneWidget);
    expect(find.text('SESSION'), findsOneWidget);
    expect(find.byType(ConversationRuntimeSettingsBar), findsOneWidget);
    expect(find.byType(ConversationParityDisclosurePanel), findsOneWidget);
    expect(find.text('/work/project-alpha'), findsOneWidget);
    expect(find.text('5 messages'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connection section surfaces the shared status chips', (
    tester,
  ) async {
    final target = paneTestTarget(
      target: 'hermes',
      label: 'Hermes',
      location: 'virtual-machine',
      binaryPath: 'hermes',
      runtimeConnection: {
        'kind': 'ssh',
        'host': 'vm.example',
        'port': 2222,
        'user': 'agent-user',
        'remoteExecutable': 'hermes',
        'workingDirectory': '/fixture-root/project',
      },
    );
    await tester.pumpWidget(
      paneTestApp(
        MessagingDetailsPanel(
          state: _panelState(target: target),
          actions: paneTestActions(),
          opencodeServeState: const AgentConversationServeState(
            status: AgentConversationServeStatus.running,
            port: 4096,
            portConflict: false,
          ),
        ),
      ),
    );

    expect(find.text('CONNECTION'), findsOneWidget);
    expect(
      find.byKey(const Key('conversation-virtual-machine-destination')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('local targets without serve state hide the connection section', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        MessagingDetailsPanel(state: _panelState(), actions: paneTestActions()),
      ),
    );

    expect(find.text('CONNECTION'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new conversation offers the working-directory chooser', (
    tester,
  ) async {
    var chooseCount = 0;
    await tester.pumpWidget(
      paneTestApp(
        MessagingDetailsPanel(
          state: _panelState(
            showWorkingDirectory: true,
            workingDirectory: '/fixture-root/project',
            workingDirectorySelectable: true,
          ),
          actions: paneTestActions(
            onChooseWorkingDirectory: () => chooseCount += 1,
          ),
        ),
      ),
    );

    final chip = find.byKey(
      const ValueKey('conversation-working-directory-select'),
    );
    expect(chip, findsOneWidget);
    expect(find.textContaining('fixture'), findsWidgets);
    expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);

    await tester.tap(chip);
    await tester.pump();
    expect(chooseCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('open session shows the bound directory without a chooser', (
    tester,
  ) async {
    var chooseCount = 0;
    const session = AgentConversationSession(
      id: 'session-1',
      agentId: 'codex',
      title: 'Focused session',
      createdAt: '2026-07-16T08:30:00',
      updatedAt: '2026-07-16T09:00:00',
      messages: [],
      workingDirectory: '/work/project-alpha',
      messageCount: 5,
    );
    await tester.pumpWidget(
      paneTestApp(
        MessagingDetailsPanel(
          state: _panelState(
            session: session,
            showWorkingDirectory: true,
            workingDirectory: '/work/project-alpha',
            workingDirectorySelectable: false,
          ),
          actions: paneTestActions(
            onChooseWorkingDirectory: () => chooseCount += 1,
          ),
        ),
      ),
    );

    final chip = find.byKey(
      const ValueKey('conversation-working-directory-select'),
    );
    expect(chip, findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);

    await tester.tap(chip);
    await tester.pump();
    expect(chooseCount, 0);
    expect(tester.takeException(), isNull);
  });
}

AgentConversationPaneState _panelState({
  AgentConversationSession? session,
  TargetCandidate? target,
  bool showWorkingDirectory = false,
  String workingDirectory = '',
  bool workingDirectorySelectable = false,
}) => AgentConversationPaneState(
  target: target ?? paneTestTarget(),
  session: session,
  liveMessages: const [],
  recentSessions: const [],
  loading: false,
  turnActive: false,
  preparingNewConversation: false,
  composerEnabled: true,
  sendGateReasonCode: '',
  composerDraft: '',
  modelOptions: const ['fixture-model'],
  selectedModel: 'fixture-model',
  defaultModel: 'fixture-model',
  reasoningEffortOptions: const ['low', 'high'],
  selectedReasoningEffort: 'low',
  showWorkingDirectory: showWorkingDirectory,
  workingDirectory: workingDirectory,
  workingDirectorySelectable: workingDirectorySelectable,
);
