import '../support/client_controller_scenario_dependencies.dart';
import '../support/client_controller_scenario_json.dart';
import '../support/fake_agent_service.dart';

void registerClientHistoryRuntimeMessageDispatchScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sendConversationMessage routes through runtime adapter without local append',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-controller-runtime-send-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-codex-1',
            agentId: 'codex',
            text: 'Existing native Codex history',
          ),
        ];
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: service,
      );
      addTearDown(controller.dispose);

      await controller.scanTargets();
      await controller.selectConversationAgent('codex');
      controller.selectConversationSession('native-codex-1');
      await controller.sendConversationMessage('  Hello Codex  ');

      expect(service.runtimeMessageCalls, 1);
      expect(service.lastRuntimeMessageRequest, {
        'agent': 'codex',
        'text': 'Hello Codex',
        'streamEvents': true,
        'timeoutMs': 0,
        'sessionId': 'native-codex-1',
        'sessionPath': 'test-data/codex/history.jsonl',
        'workingDirectory': localConversationWorkingDirectoryFallback(
          agentId: 'codex',
        ),
        'binaryPath': ['', 'opt', 'lico-test', 'bin', 'codex'].join('/'),
      });
      expect(service.conversationAppendCalls, 0);
      expect(controller.selectedConversationSessions, hasLength(1));
      expect(controller.lastError, isEmpty);
      expect(
        controller.statusMessage,
        'Sent the message through the Codex runtime adapter.',
      );
      controller.localePreference = 'en';
      expect(
        controller.displayStatusMessage,
        'Sent the message through the Codex runtime adapter.',
      );
    },
  );
}
