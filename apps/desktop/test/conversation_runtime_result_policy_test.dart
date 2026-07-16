import 'package:flutter_client/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime errors expose only bounded stable codes', () {
    expect(
      ConversationRuntimeResultPolicy.errorCode({
        'error': {'code': 'native_timeout'},
      }),
      'native_timeout',
    );
    expect(
      ConversationRuntimeResultPolicy.errorCode({
        'error': {'code': 'unsafe code with details'},
      }),
      'native_agent_dispatch_failed',
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
}
