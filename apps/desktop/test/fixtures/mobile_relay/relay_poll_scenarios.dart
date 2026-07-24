import 'dart:convert';

import 'package:licoup/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

var _synthSeq = 0;
String _synth(String label) => '$label-${_synthSeq++}';

final sv_relay_command_canary = _synth('relay-command-canary');
final sv_idempotency_canary = _synth('idempotency-canary');
final sv_payload_command_canary = _synth('payload-command-canary');

void registerMobileRelayPollScenarios() {
  test('secure relay poll accepts a validated runtime result', () {
  final sv_relay_result_canary = _synth('relay-result-canary');
    final polled = <String, dynamic>{
      'ok': true,
      'response': {
        'command': {'commandId': sv_relay_command_canary, 'status': 'completed'},
      },
      'openedResult': {
        'execution': {
          'commandId': sv_payload_command_canary,
          'idempotencyKey': sv_idempotency_canary,
          'outcome': 'result',
          'output': {
            'ok': true,
            'commandKind': 'agent.message.send',
            'output': {'ok': true, 'content': sv_relay_result_canary},
          },
        },
      },
    };

    final completion = resolveSecureRelayPollResult(
      created:  {
        'ok': true,
        'command': {'commandId': sv_relay_command_canary},
        'secureCommandBinding': {
          'payloadCommandId': sv_payload_command_canary,
          'idempotencyKey': sv_idempotency_canary,
          'commandKind': 'agent.message.send',
        },
      },
      polled: polled,
    );

    expect(completion?['ok'], isTrue);
    expect(completion?['result'], same(polled));
  });

  test('secure relay poll rejects a result swapped across commands', () {
  final sv_idempotency_other = _synth('idempotency-other');
  final sv_idempotency_expected = _synth('idempotency-expected');
    final completion = resolveSecureRelayPollResult(
      created:  {
        'ok': true,
        'command': {'commandId': 'relay-command-expected'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-expected',
          'idempotencyKey': sv_idempotency_expected,
          'commandKind': 'agent.message.send',
        },
      },
      polled:  {
        'ok': true,
        'response': {
          'command': {
            'commandId': 'relay-command-other',
            'status': 'completed',
          },
        },
        'openedResult': {
          'execution': {
            'commandId': 'payload-command-other',
            'idempotencyKey': sv_idempotency_other,
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {'ok': true},
            },
          },
        },
      },
    );

    expect(completion, const {
      'ok': false,
      'errorCode': 'secure_relay_command_binding_mismatch',
    });
  });

  test('secure relay poll returns only a redacted execution error code', () {
  final sv_private_error_detail_can = _synth('private-error-detail-canary');
    final completion = resolveSecureRelayPollResult(
      created:  {
        'ok': true,
        'command': {'commandId': sv_relay_command_canary},
        'secureCommandBinding': {
          'payloadCommandId': sv_payload_command_canary,
          'idempotencyKey': sv_idempotency_canary,
          'commandKind': 'agent.message.send',
        },
      },
      polled:  {
        'ok': true,
        'response': {
          'command': {'commandId': sv_relay_command_canary, 'status': 'failed'},
        },
        'openedResult': {
          'execution': {
            'commandId': sv_payload_command_canary,
            'idempotencyKey': sv_idempotency_canary,
            'outcome': 'error',
            'errorCode': 'command_replay_rejected',
            'errorDetail': sv_private_error_detail_can,
          },
        },
      },
    );

    expect(completion, const {
      'ok': false,
      'errorCode': 'command_replay_rejected',
    });
    expect(
      jsonEncode(completion),
      isNot(contains(sv_private_error_detail_can)),
    );
  });

  test('secure relay poll fails closed when nested runtime output fails', () {
  final sv_private_runtime_detail_c = _synth('private-runtime-detail-canary');
    final completion = resolveSecureRelayPollResult(
      created:  {
        'ok': true,
        'command': {'commandId': sv_relay_command_canary},
        'secureCommandBinding': {
          'payloadCommandId': sv_payload_command_canary,
          'idempotencyKey': sv_idempotency_canary,
          'commandKind': 'agent.message.send',
        },
      },
      polled:  {
        'ok': true,
        'response': {
          'command': {
            'commandId': sv_relay_command_canary,
            'status': 'completed',
          },
        },
        'openedResult': {
          'execution': {
            'commandId': sv_payload_command_canary,
            'idempotencyKey': sv_idempotency_canary,
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {
                'ok': false,
                'errorCode': 'unsafe error detail',
                'error': sv_private_runtime_detail_c,
              },
            },
          },
        },
      },
    );

    expect(completion, const {
      'ok': false,
      'errorCode': 'secure_relay_runtime_failed',
    });
    expect(
      jsonEncode(completion),
      isNot(contains(sv_private_runtime_detail_c)),
    );
  });

  test('secure relay poll rejects malformed opened result structure', () {
    const malformedOpenedResults = <Map<String, dynamic>>[
      {'unexpected': true},
      {
        'execution': {
          'commandId': sv_payload_command_canary,
          'idempotencyKey': sv_idempotency_canary,
          'outcome': 'result',
        },
      },
      {
        'execution': {
          'commandId': sv_payload_command_canary,
          'idempotencyKey': sv_idempotency_canary,
          'outcome': 'result',
          'output': {'ok': true},
        },
      },
      {
        'execution': {
          'commandId': sv_payload_command_canary,
          'idempotencyKey': sv_idempotency_canary,
          'outcome': 'result',
          'output': {
            'ok': true,
            'commandKind': 'agent.message.send',
            'output': {'content': 'missing-ok-must-not-pass'},
          },
        },
      },
    ];

    for (final openedResult in malformedOpenedResults) {
      final completion = resolveSecureRelayPollResult(
        created:  {
          'ok': true,
          'command': {'commandId': sv_relay_command_canary},
          'secureCommandBinding': {
            'payloadCommandId': sv_payload_command_canary,
            'idempotencyKey': sv_idempotency_canary,
            'commandKind': 'agent.message.send',
          },
        },
        polled: {
          'ok': true,
          'response': {
            'command': {
              'commandId': sv_relay_command_canary,
              'status': 'completed',
            },
          },
          'openedResult': openedResult,
        },
      );

      expect(completion, const {
        'ok': false,
        'errorCode': 'secure_relay_result_invalid',
      });
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerMobileRelayPollScenarios();
}
