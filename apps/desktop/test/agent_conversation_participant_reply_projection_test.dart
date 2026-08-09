import 'fixtures/client_controller/support/client_controller_scenario_dependencies.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'package:licoup/src/platform/agents/subagent_handoff_store.dart';

/// M1: peer participant replies and subagent handoff bubbles must render on
/// the live turn blackboard. The blackboard is bound to the live turn id, so
/// derived ids (`-participant-<agentId>` / `-handoff-<dispatchId>` suffixes)
/// must route to the same turn while stale events of a replaced turn stay
/// dropped.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('peer participant replies render on the live turn blackboard', () async {
    final service = FakeAgentService()
      ..runtimeMessageStreamEventQueue = [
        [
          {
            'event': 'agent.message.completed',
            'sessionId': 'native-codex-1',
            'payload': {
              'text': 'Architecture ready',
              'participantAgentId': 'designer',
              'participantLabel': 'Designer',
              'participantRole': 'designer',
            },
          },
          {
            'event': 'agent.message.completed',
            'sessionId': 'native-codex-1',
            'payload': {
              'text': 'Implementation ready',
              'participantAgentId': 'backend-worker',
              'participantLabel': 'Backend Worker',
              'participantRole': 'backend-worker',
            },
          },
        ],
      ];
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);
    controller.scannedTargets = [_codexTarget()];
    controller.selectedConversationAgentId = 'codex';
    final scopeKey = controller.conversationComposerScopeKey;

    final sent = await controller.sendConversationMessage('Build it');
    expect(sent, isTrue);

    final live = controller.liveConversationMessagesByScope[scopeKey]!;
    final assistants = live
        .where(
          (message) =>
              message.role == 'assistant' && message.text.trim().isNotEmpty,
        )
        .toList();
    expect(
      assistants.map((message) => message.participantAgentId),
      containsAll(<String>['codex', 'designer', 'backend-worker']),
    );
    expect(
      assistants.map((message) => message.text),
      containsAll(<String>['Architecture ready', 'Implementation ready']),
    );
    // The turn's own reply keeps the plain assistant identity; each peer
    // bubble gets a stable per-participant identity.
    expect(
      assistants.where((message) => message.id.endsWith('-assistant')),
      hasLength(1),
    );
    expect(
      assistants.where(
        (message) => message.id.contains('-assistant-designer-'),
      ),
      hasLength(1),
    );
    expect(
      assistants.where(
        (message) => message.id.contains('-assistant-backend-worker-'),
      ),
      hasLength(1),
    );
  });

  test('subagent handoff bubbles project onto the live turn', () async {
    final directory = await Directory.systemTemp.createTemp('lico-handoff-');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final handoffDirectory = await SubagentHandoffStore.root(portableData);
    await handoffDirectory.create(recursive: true);
    await File('${handoffDirectory.path}/dispatch-1.json').writeAsString(
      jsonEncode({
        'dispatchId': 'dispatch-1',
        'operation': 'delegate',
        'managerAgentId': 'codex',
        'agentId': 'designer',
        'state': 'completed',
        'sessionMode': 'new',
        'updatedAtUnixMs': 1720000000000,
      }),
    );
    final controller = ClientController(
      agentService: FakeAgentService(),
      portableData: portableData,
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [_codexTarget()];
    controller.selectedConversationAgentId = agentOrchestrationTargetId;

    final scopeKey = controller.conversationComposerScopeKey;
    controller.conversationStartLiveProjection(
      scopeKey: scopeKey,
      turnId: 'live-codex-1720000000000000',
      userText: 'Build it',
    );

    await controller.projectSubagentHandoffPeerBubbles();

    final live = controller.liveConversationMessagesByScope[scopeKey]!;
    final bubbles = live
        .where(
          (message) =>
              message.role == 'assistant' && message.text.trim().isNotEmpty,
        )
        .toList();
    expect(bubbles, hasLength(1));
    expect(bubbles.single.participantAgentId, 'designer');
    expect(bubbles.single.participantRole, 'peer-agent');
    expect(bubbles.single.text, contains('finished'));
    expect(
      bubbles.single.id,
      'live-codex-1720000000000000-assistant-designer-peer-agent',
    );

    // A second projection pass must not duplicate the bubble.
    await controller.projectSubagentHandoffPeerBubbles();
    expect(
      controller.liveConversationMessagesByScope[scopeKey]!
          .where((message) => message.role == 'assistant')
          .length,
      1,
    );
  });

  test('stale participant and handoff events of a replaced turn are dropped',
      () {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);
    const scopeKey = 'session:codex:session-1';
    controller.conversationStartLiveProjection(
      scopeKey: scopeKey,
      turnId: 'live-codex-111',
      userText: 'Request',
    );

    // Events whose ids derive from a different (replaced) turn must not
    // corrupt the current blackboard.
    expect(
      controller.conversationUpsertLiveReply(
        scopeKey: scopeKey,
        turnId: 'live-codex-222-participant-designer',
        text: 'Stale peer reply',
        participantAgentId: 'designer',
        participantRole: 'designer',
      ),
      isFalse,
    );
    expect(
      controller.conversationUpsertLiveReply(
        scopeKey: scopeKey,
        turnId: 'live-codex-222-handoff-dispatch-9',
        text: 'Stale handoff bubble',
        participantAgentId: 'designer',
        participantRole: 'peer-agent',
      ),
      isFalse,
    );
    expect(
      controller.conversationUpsertLiveReply(
        scopeKey: scopeKey,
        turnId: 'live-codex-111-handoff-dispatch-7',
        text: 'Handoff bubble finished',
        participantAgentId: 'designer',
        participantRole: 'peer-agent',
      ),
      isTrue,
    );
    final live = controller.liveConversationMessagesByScope[scopeKey]!;
    expect(
      live
          .where((message) => message.role == 'assistant')
          .map((message) => message.text),
      ['Handoff bubble finished'],
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
    adapterCapabilities: const <String, dynamic>{
      'conversationDriver': 'implemented',
      'conversationProtocol': 'synthetic-native-protocol',
      'conversationReadiness': 'ready',
    },
  );
}
