import 'dart:convert';

import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_native_dispatch.dart';
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
    expect(arguments.take(5), [
      'mobile',
      'relay',
      'commands',
      'create-secure',
      '--client-intent-id',
    ]);
    expect(arguments[5], isNotEmpty);
    expect(
      arguments,
      containsAllInOrder([
        '--command-kind',
        'agent.message.send',
        '--target-agent-id',
        'agent-a',
      ]),
    );
    final body = jsonDecode(arguments.last) as Map<String, dynamic>;
    expect(body['text'], 'hello');
    expect(body['model'], 'model-a');
    expect(body.keys, isNot(contains('agent')));
    expect(body.keys, isNot(contains('agentId')));
    expect(body.keys, isNot(contains('target')));
  });

  test(
    'mobile consumer accepts the native direct create and result contracts',
    () async {
      var createAttempts = 0;
      var resultPolls = 0;
      final dispatch = FakeMobileRelayDispatch(
        isAndroid: true,
        onRunMobile:
            ({
              required String action,
              required Map<String, dynamic> params,
              required bool authorize,
            }) async {
              expect(authorize, isTrue);
              if (action == 'mobile.relay.commands.createSecure') {
                createAttempts += 1;
                if (createAttempts == 1) {
                  throw const MobileRelayDispatchException(
                    'injected_create_response_loss',
                  );
                }
                expect(params['targetAgentId'], 'agent-a');
                expect(params['body'], const {'text': 'hello'});
                expect(params['clientIntentId'], isA<String>());
                expect(
                  (params['clientIntentId'] as String).length,
                  greaterThan(20),
                );
                return const {
                  'ok': true,
                  'schemaVersion': 2,
                  'transportHint': {
                    'stationReportedAccepted': true,
                    'stationReportedDuplicate': false,
                  },
                  'secureCommandBinding': {
                    'payloadCommandId': 'payload-command-native',
                    'idempotencyKey': 'idempotency-native',
                    'commandKind': 'agent.message.send',
                    'recoveredPendingDelivery': false,
                  },
                };
              }
              expect(action, 'mobile.relay.commands.resultSecure');
              if (params.containsKey('acknowledgeReceiptId')) {
                expect(params['acknowledgeReceiptId'], 'result-receipt-native');
                return const {
                  'ok': true,
                  'acknowledged': true,
                  'bodyRedacted': true,
                };
              }
              expect(params, const {
                'commandId': 'payload-command-native',
                'idempotencyKey': 'idempotency-native',
              });
              resultPolls += 1;
              if (resultPolls == 1) {
                return const {
                  'ok': true,
                  'schemaVersion': 2,
                  'openedResult': null,
                  'pending': true,
                  'bodyRedacted': true,
                };
              }
              return const {
                'ok': true,
                'schemaVersion': 2,
                'pending': false,
                'resultReceiptId': 'result-receipt-native',
                'openedResult': {
                  'execution': {
                    'commandId': 'payload-command-native',
                    'idempotencyKey': 'idempotency-native',
                    'outcome': 'result',
                    'output': {
                      'ok': true,
                      'commandKind': 'agent.message.send',
                      'output': {
                        'ok': true,
                        'adapterId': 'agent-a',
                        'content': 'native-result-canary',
                      },
                    },
                  },
                },
                'bodyRedacted': true,
                'transportHint': {
                  'lease': {'stationReportedLeased': true},
                  'delete': {'stationReportedAcknowledged': true},
                },
              };
            },
      );
      final operations = MobileRelaySecureConversationOperations(
        dispatch: dispatch,
        delay: (_) async {},
      );

      final result = await operations.sendSecureAgentMessage(
        agentService: FakeAgentCommandRunner(),
        agentId: 'agent-a',
        text: 'hello',
      );

      expect(result['ok'], isTrue);
      expect(result['resultReceiptAcknowledged'], isTrue);
      expect(createAttempts, 2);
      expect(resultPolls, 2);
      expect(dispatch.cliCalls, isEmpty);
      expect(dispatch.mobileCalls.map((call) => call.action), [
        'mobile.relay.commands.createSecure',
        'mobile.relay.commands.createSecure',
        'mobile.relay.commands.resultSecure',
        'mobile.relay.commands.resultSecure',
        'mobile.relay.commands.resultSecure',
      ]);
      expect(dispatch.mobileCalls[0].params, dispatch.mobileCalls[1].params);
      final nativeResult = result['result'] as Map<String, dynamic>;
      expect(nativeResult['bodyRedacted'], isTrue);
      expect(
        nativeResult['openedResult']['execution']['commandId'],
        'payload-command-native',
      );
    },
  );

  test(
    'session command bodies keep agent selection at the outer boundary',
    () async {
      final dispatch = FakeMobileRelayDispatch(
        isAndroid: true,
        mobileResult: const {'ok': false},
      );
      final operations = MobileRelaySecureConversationOperations(
        dispatch: dispatch,
        delay: (_) async {},
      );

      await operations.listSecureAgentSessions(
        agentId: 'agent-a',
        limit: 7,
        offset: 2,
      );
      await operations.describeSecureAgentSession(
        agentId: 'agent-a',
        sessionId: 'native-session-a',
      );

      expect(dispatch.mobileCalls, hasLength(2));
      final listParams = Map<String, dynamic>.from(
        dispatch.mobileCalls[0].params,
      );
      final listIntentId = listParams.remove('clientIntentId');
      expect(listIntentId, isA<String>());
      expect(listParams, const {
        'commandKind': 'agent.sessions.list',
        'targetAgentId': 'agent-a',
        'workspaceId': 'default',
        'body': {'limit': 7, 'offset': 2},
      });
      final describeParams = Map<String, dynamic>.from(
        dispatch.mobileCalls[1].params,
      );
      final describeIntentId = describeParams.remove('clientIntentId');
      expect(describeIntentId, isA<String>());
      expect(describeIntentId, isNot(listIntentId));
      expect(describeParams, const {
        'commandKind': 'agent.sessions.describe',
        'targetAgentId': 'agent-a',
        'workspaceId': 'default',
        'body': {
          'sessionId': 'native-session-a',
          'nativeSessionId': 'native-session-a',
        },
      });
    },
  );

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

  test('desktop protocol actions fail before any dispatch', () async {
    final dispatch = FakeMobileRelayDispatch();
    final operations = SecureMeshProtocolOperations(dispatch: dispatch);

    final unsupported = isA<UnsupportedError>().having(
      (error) => error.message,
      'message',
      secureMeshProtocolMobileOnlyErrorCode,
    );
    await expectLater(
      operations.executeSecureMeshKtRequest(
        request: const SecureMeshKtRequest.status(),
      ),
      throwsA(unsupported),
    );
    await expectLater(
      operations.executeSecureMeshMlsRequest(
        request: const SecureMeshMlsRequest.status(),
      ),
      throwsA(unsupported),
    );

    expect(dispatch.cliCalls, isEmpty);
    expect(dispatch.privateCliCalls, isEmpty);
    expect(dispatch.mobileCalls, isEmpty);
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
    'KT protocol component uses its generated protected mobile action',
    () async {
      final dispatch = FakeMobileRelayDispatch(
        isIOS: true,
        mobileResult: const {'ok': true, 'privateKeyMaterial': 'redacted'},
      );
      final operations = SecureMeshProtocolOperations(dispatch: dispatch);

      final response = await operations.executeSecureMeshKtRequest(
        request: SecureMeshKtRequest.publicationRequest(endpointKind: 'device'),
      );

      expect(response.value['ok'], isTrue);
      expect(dispatch.cliCalls, isEmpty);
      expect(
        dispatch.mobileCalls.single.action,
        'secure_mesh.kt.publicationRequest',
      );
      expect(dispatch.mobileCalls.single.authorize, isTrue);
      expect(dispatch.mobileCalls.single.params, {
        'endpointKind': 'device',
        'allowInteraction': true,
      });
    },
  );

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
