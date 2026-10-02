import 'package:licoup/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime errors expose only bounded stable codes', () {
    expect(
      ConversationRuntimeResultPolicy.clientError({
        'error': {
          'code': 'authorization_required',
          'stage': 'conversation/dispatch',
          'component': 'conversation_runtime',
          'retryable': false,
          'recovery': 'correct_request',
        },
      }).code.wireName,
      'authorization_required',
    );
    expect(
      ConversationRuntimeResultPolicy.clientError({
        'error': {'code': 'unsafe code with details'},
      }).isUnknown,
      isTrue,
    );
  });

  test('submission consumption is explicit and bounded', () {
    expect(ConversationRuntimeResultPolicy.submissionConsumed(''), isTrue);
    expect(
      ConversationRuntimeResultPolicy.submissionConsumed(
        'conversation_turn_duplicate_ignored',
      ),
      isTrue,
    );
    expect(
      ConversationRuntimeResultPolicy.submissionConsumed(
        'conversation_turn_queue_full',
      ),
      isFalse,
    );
  });

  test('effective settings fail closed for direct and relay projections', () {
    expect(
      ConversationRuntimeResultPolicy.effectiveSettingsMatch(
        {
          'effective': {'model': 'gpt-5', 'reasoningEffort': 'high'},
        },
        throughMobileRelay: false,
        requestedModel: 'gpt-5',
        requestedReasoningEffort: 'high',
      ),
      isTrue,
    );
    expect(
      ConversationRuntimeResultPolicy.effectiveSettingsMatch(
        const {},
        throughMobileRelay: false,
        requestedModel: 'gpt-5',
        requestedReasoningEffort: '',
      ),
      isFalse,
    );
    expect(
      ConversationRuntimeResultPolicy.effectiveSettingsMatch(
        {
          'result': {
            'openedResult': {
              'execution': {
                'output': {
                  'output': {
                    'effective': {'model': 'gpt-5'},
                  },
                },
              },
            },
          },
        },
        throughMobileRelay: true,
        requestedModel: 'gpt-5',
        requestedReasoningEffort: '',
      ),
      isTrue,
    );
  });

  test('progressive text merge avoids duplicate cumulative chunks', () {
    expect(
      ConversationRuntimeResultPolicy.mergeProgressiveText(
        'Hello',
        'Hello world',
        completed: false,
      ),
      'Hello world',
    );
    expect(
      ConversationRuntimeResultPolicy.mergeProgressiveText(
        'Hello world',
        'world',
        completed: false,
      ),
      'Hello world',
    );
    expect(
      ConversationRuntimeResultPolicy.mergeProgressiveText(
        'Hello ',
        'world',
        completed: false,
      ),
      'Hello world',
    );
  });

  test('driver failure codes survive outside the schema enum', () {
    // Driver envelope codes (copilot_acp_*, hermes_gateway_*, …) are not part
    // of the schema-bound ClientErrorCode enum; they must still surface.
    final driverResult = <String, dynamic>{
      'ok': false,
      'error': <String, dynamic>{
        'code': 'copilot_acp_session_update_invalid',
        'message': 'The ACP protocol message could not be processed safely.',
        'stage': 'session/update',
        'userInteractionRequired': false,
      },
    };
    expect(
      ConversationRuntimeResultPolicy.clientError(driverResult).code.wireName,
      isEmpty,
    );
    expect(
      ConversationRuntimeResultPolicy.rawFailureCode(driverResult),
      'copilot_acp_session_update_invalid',
    );
    expect(
      ConversationRuntimeResultPolicy.surfacedFailureCode(driverResult),
      'copilot_acp_session_update_invalid',
    );

    final schemaResult = <String, dynamic>{
      'ok': false,
      'error': <String, dynamic>{
        'code': 'authorization_required',
        'stage': 'conversation/dispatch',
        'component': 'conversation_runtime',
        'retryable': false,
        'recovery': 'correct_request',
      },
    };
    expect(
      ConversationRuntimeResultPolicy.surfacedFailureCode(schemaResult),
      'authorization_required',
    );

    expect(
      ConversationRuntimeResultPolicy.surfacedFailureCode(const {}),
      'terminal_result_invalid',
    );
  });
}
