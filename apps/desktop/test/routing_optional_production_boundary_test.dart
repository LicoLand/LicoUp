import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_registration_factory.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'routing-production-boundary-',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test(
    'excluded compile creates no routing state and preserves direct dispatch',
    () async {
      final registration = createRoutingModuleRegistration(
        rootDirectory: tempDirectory,
      );
      await registration.activate();
      expect(registration.isIncluded, isFalse);
      expect(registration.isReady, isFalse);
      expect(
        await Directory(
          p.join(tempDirectory.path, routingModuleStateDirectory),
        ).exists(),
        isFalse,
      );

      final runner = _RecordingAgentService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: tempDirectory),
        agentService: runner,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [_directTarget];

      expect(controller.routingModuleIncluded, isFalse);
      expect(
        controller
            .orderedConversationTargets(controller.scannedTargets)
            .map((target) => target.target),
        ['codex'],
      );
      await controller.selectConversationAgent(agentOrchestrationTargetId);
      expect(controller.selectedConversationAgentId, isEmpty);

      await controller.selectConversationAgent('codex');
      await controller.sendConversationMessage('direct smoke');

      expect(runner.sentRequests, hasLength(1));
      expect(runner.sentRequests.single['agent'], 'codex');
      expect(runner.sentRequests.single['text'], 'direct smoke');
      expect(
        await Directory(
          p.join(tempDirectory.path, routingModuleStateDirectory),
        ).exists(),
        isFalse,
      );
    },
    skip: kRoutingModuleIncluded
        ? 'Run with LICO_ROUTING_MODULE_INCLUDED=false.'
        : false,
  );

  test(
    'production controller disables, unloads, and cleanly re-enables routing',
    () async {
      final runner = _RecordingAgentService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: tempDirectory),
        agentService: runner,
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [_directTarget];
      controller.selectedConversationAgentId = agentOrchestrationTargetId;

      await controller.saveAgentOrchestrationPolicy(
        const AgentOrchestrationPolicy(
          label: 'Production boundary',
          commanderAgentId: 'codex',
          commanderModelName: 'test-model',
        ),
      );
      expect(controller.routingModuleAvailable, isTrue);
      expect(
        await Directory(
          p.join(tempDirectory.path, routingModuleStateDirectory),
        ).exists(),
        isTrue,
      );

      await controller.setRoutingModuleEnabled(false);
      expect(controller.routingModuleAvailable, isFalse);
      expect(controller.selectedConversationAgentId, 'codex');
      expect(
        controller
            .orderedConversationTargets(controller.scannedTargets)
            .map((target) => target.target),
        ['codex'],
      );
      await controller.sendConversationMessage('runtime disabled direct');
      expect(runner.sentRequests.last['agent'], 'codex');

      await controller.unloadRoutingModule();
      expect(
        await Directory(
          p.join(tempDirectory.path, routingModuleStateDirectory),
        ).exists(),
        isFalse,
      );

      await controller.setRoutingModuleEnabled(true);
      expect(controller.routingModuleAvailable, isTrue);
      expect(
        await Directory(
          p.join(tempDirectory.path, routingModuleStateDirectory),
        ).exists(),
        isTrue,
      );
    },
    skip: kRoutingModuleIncluded
        ? false
        : 'Run with LICO_ROUTING_MODULE_INCLUDED=true.',
  );
}

final TargetCandidate _directTarget = TargetCandidate(
  target: 'codex',
  label: 'Codex',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: const {
    'conversationDriver': 'implemented',
    'conversationProtocol': 'test',
    'conversationReadiness': 'ready',
    'models': ['test-model'],
  },
  supportedActions: const ['runtime.message.send'],
);

final class _RecordingAgentService extends AgentService {
  final List<Map<String, dynamic>> sentRequests = [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    return const {'ok': true, 'sessions': <Object>[]};
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) {
    return const Stream.empty();
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    sentRequests.add(request);
    yield {
      'event': 'done',
      'ok': true,
      'nativeSessionId': 'direct-session-${sentRequests.length}',
      'sessionId': 'direct-session-${sentRequests.length}',
      'threadId': 'direct-session-${sentRequests.length}',
      'turnStatus': 'end_turn',
      'output': 'ok',
    };
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    sentRequests.add(request);
    return {
      'ok': true,
      'nativeSessionId': 'direct-session-${sentRequests.length}',
    };
  }
}
