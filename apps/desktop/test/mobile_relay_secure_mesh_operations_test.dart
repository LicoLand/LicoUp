import 'dart:convert';

import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_secure_conversation_operations.dart';
import 'package:licoup/src/platform/mobile_relay/secure_mesh_protocol_operations.dart';
import 'package:licoup/src/platform/mobile_relay/secure_mesh_substrate_operations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_mobile_relay_dispatch.dart';

void main() {
  test('secure conversation component builds desktop relay commands', () async {
    final dispatch = FakeMobileRelayDispatch(
      cliResult: const {'ok': true, 'status': 'created'},
    );
    final operations = MobileRelaySecureConversationOperations(
      dispatch: dispatch,
    );

    final result = await operations.sendSecureAgentMessage(
      agentService: FakeAgentCommandRunner(),
      agentId: 'agent-a',
      text: 'hello',
      model: 'model-a',
    );

    expect(result['status'], 'created');
    expect(dispatch.cliCalls, hasLength(1));
    final arguments = dispatch.cliCalls.single;
    expect(arguments.take(8), [
      'mobile',
      'relay',
      'commands',
      'create-secure',
      '--command-kind',
      'agent.message.send',
      '--target-agent-id',
      'agent-a',
    ]);
    final body = jsonDecode(arguments.last) as Map<String, dynamic>;
    expect(body['agentId'], 'agent-a');
    expect(body['model'], 'model-a');
  });

  test(
    'secure conversation validation closes before native dispatch',
    () async {
      final dispatch = FakeMobileRelayDispatch(isAndroid: true);
      final operations = MobileRelaySecureConversationOperations(
        dispatch: dispatch,
      );

      final result = await operations.listSecureAgentSessions(agentId: '   ');

      expect(result['errorCode'], 'secure_agent_sessions_agent_id_missing');
      expect(dispatch.mobileCalls, isEmpty);
    },
  );

  test('KT protocol component maps status to the desktop CLI', () async {
    final dispatch = FakeMobileRelayDispatch(
      cliResult: const {'ok': true, 'privateKeyMaterial': 'redacted'},
    );
    final operations = SecureMeshProtocolOperations(dispatch: dispatch);

    final response = await operations.executeSecureMeshKtRequest(
      agentService: FakeAgentCommandRunner(),
      request: const SecureMeshKtRequest.status(),
    );

    expect(response.value['ok'], isTrue);
    expect(dispatch.cliCalls, [
      ['mobile', 'relay', 'kt', 'status'],
    ]);
  });

  test('MLS protocol component uses its dedicated mobile action', () async {
    final dispatch = FakeMobileRelayDispatch(
      isAndroid: true,
      mobileResult: const {'ok': true, 'privateKeyMaterial': 'redacted'},
    );
    final operations = SecureMeshProtocolOperations(dispatch: dispatch);

    final response = await operations.executeSecureMeshMlsRequest(
      request: const SecureMeshMlsRequest.status(),
    );

    expect(response.value['ok'], isTrue);
    expect(dispatch.mobileCalls.single.action, 'secure_mesh.mls.status');
    expect(dispatch.mobileCalls.single.authorize, isFalse);
  });

  test(
    'file and approval substrate stays on its dedicated CLI surface',
    () async {
      final dispatch = FakeMobileRelayDispatch(cliResult: const {'ok': true});
      final operations = SecureMeshSubstrateOperations(dispatch: dispatch);
      final runner = FakeAgentCommandRunner();

      await operations.evaluateSecureMeshFileRoute(
        agentService: runner,
        manifest: const {'objectId': 'artifact-a'},
      );
      await operations.evaluateSecureMeshApprovalRequest(
        agentService: runner,
        request: const {
          'pendingOperationId': 'pending-a',
          'requiredCapabilityIds': ['read'],
        },
      );

      expect(dispatch.cliCalls[0].take(4), [
        'secure-mesh',
        'file',
        'route',
        '--manifest',
      ]);
      expect(dispatch.cliCalls[1].take(3), [
        'secure-mesh',
        'approval',
        'request',
      ]);
      expect(dispatch.cliCalls[1], contains('--required-capability-ids'));
    },
  );

  test(
    'file substrate dispatches mobile routing without CLI coupling',
    () async {
      final dispatch = FakeMobileRelayDispatch(isAndroid: true);
      final operations = SecureMeshSubstrateOperations(dispatch: dispatch);

      await operations.evaluateSecureMeshFileRoute(
        agentService: FakeAgentCommandRunner(),
        manifest: const {'objectId': 'artifact-a'},
      );

      expect(dispatch.cliCalls, isEmpty);
      expect(dispatch.mobileCalls.single.action, 'secure_mesh.file.route');
      expect(dispatch.mobileCalls.single.params, {
        'manifest': {'objectId': 'artifact-a'},
      });
    },
  );

  test('iOS command execution uses the native protected action', () async {
    final dispatch = FakeMobileRelayDispatch(
      isIOS: true,
      mobileResult: const {'ok': true},
    );
    final operations = SecureMeshSubstrateOperations(dispatch: dispatch);

    await operations.executeSecureMeshCommand(
      agentService: FakeAgentCommandRunner(),
      payload: const {'commandId': 'command-a'},
      context: const {'userConfirmed': true},
      completedAt: '2026-07-16T00:00:00Z',
    );

    expect(dispatch.cliCalls, isEmpty);
    expect(dispatch.mobileCalls.single.action, 'secure_mesh.command.execute');
    expect(dispatch.mobileCalls.single.authorize, isTrue);
    expect(dispatch.mobileCalls.single.params, {
      'payload': {'commandId': 'command-a'},
      'context': {'userConfirmed': true},
      'completedAt': '2026-07-16T00:00:00Z',
    });
  });

  test('iOS device trust evaluation uses the shared native core', () async {
    final dispatch = FakeMobileRelayDispatch(
      isIOS: true,
      mobileResult: const {'ok': true},
    );
    final operations = SecureMeshSubstrateOperations(dispatch: dispatch);

    await operations.evaluateSecureMeshDeviceTrust(
      agentService: FakeAgentCommandRunner(),
      identity: const {'endpointId': 'endpoint-a'},
      trustState: 'verified',
    );

    expect(dispatch.cliCalls, isEmpty);
    expect(
      dispatch.mobileCalls.single.action,
      'secure_mesh.deviceTrust.evaluate',
    );
    expect(dispatch.mobileCalls.single.authorize, isFalse);
  });
}
