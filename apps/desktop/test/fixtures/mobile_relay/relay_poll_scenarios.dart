import 'dart:convert';

import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

void registerMobileRelayPollScenarios() {
  test('secure relay poll accepts a validated runtime result', () {
    final polled = <String, dynamic>{
      'ok': true,
      'response': {
        'command': {'commandId': 'relay-command-canary', 'status': 'completed'},
      },
      'openedResult': {
        'execution': {
          'commandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'outcome': 'result',
          'output': {
            'ok': true,
            'commandKind': 'agent.message.send',
            'output': {'ok': true, 'content': 'relay-result-canary'},
          },
        },
      },
    };

    final completion = resolveSecureRelayPollResult(
      created: const {
        'ok': true,
        'command': {'commandId': 'relay-command-canary'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'commandKind': 'agent.message.send',
        },
      },
      polled: polled,
    );

    expect(completion?['ok'], isTrue);
    expect(completion?['result'], same(polled));
  });

  test('secure relay poll rejects a result swapped across commands', () {
    final completion = resolveSecureRelayPollResult(
      created: const {
        'ok': true,
        'command': {'commandId': 'relay-command-expected'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-expected',
          'idempotencyKey': 'idempotency-expected',
          'commandKind': 'agent.message.send',
        },
      },
      polled: const {
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
            'idempotencyKey': 'idempotency-other',
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
    final completion = resolveSecureRelayPollResult(
      created: const {
        'ok': true,
        'command': {'commandId': 'relay-command-canary'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'commandKind': 'agent.message.send',
        },
      },
      polled: const {
        'ok': true,
        'response': {
          'command': {'commandId': 'relay-command-canary', 'status': 'failed'},
        },
        'openedResult': {
          'execution': {
            'commandId': 'payload-command-canary',
            'idempotencyKey': 'idempotency-canary',
            'outcome': 'error',
            'errorCode': 'command_replay_rejected',
            'errorDetail': 'private-error-detail-canary',
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
      isNot(contains('private-error-detail-canary')),
    );
  });

  test('secure relay poll fails closed when nested runtime output fails', () {
    final completion = resolveSecureRelayPollResult(
      created: const {
        'ok': true,
        'command': {'commandId': 'relay-command-canary'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'commandKind': 'agent.message.send',
        },
      },
      polled: const {
        'ok': true,
        'response': {
          'command': {
            'commandId': 'relay-command-canary',
            'status': 'completed',
          },
        },
        'openedResult': {
          'execution': {
            'commandId': 'payload-command-canary',
            'idempotencyKey': 'idempotency-canary',
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {
                'ok': false,
                'errorCode': 'unsafe error detail',
                'error': 'private-runtime-detail-canary',
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
      isNot(contains('private-runtime-detail-canary')),
    );
  });

  test('secure relay poll rejects malformed opened result structure', () {
    const malformedOpenedResults = <Map<String, dynamic>>[
      {'unexpected': true},
      {
        'execution': {
          'commandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'outcome': 'result',
        },
      },
      {
        'execution': {
          'commandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'outcome': 'result',
          'output': {'ok': true},
        },
      },
      {
        'execution': {
          'commandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
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
        created: const {
          'ok': true,
          'command': {'commandId': 'relay-command-canary'},
          'secureCommandBinding': {
            'payloadCommandId': 'payload-command-canary',
            'idempotencyKey': 'idempotency-canary',
            'commandKind': 'agent.message.send',
          },
        },
        polled: {
          'ok': true,
          'response': {
            'command': {
              'commandId': 'relay-command-canary',
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
