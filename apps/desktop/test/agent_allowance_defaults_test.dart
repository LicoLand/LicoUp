import 'package:flutter_client/src/application/features/agents/models/agent_allowance_defaults.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns the unchanged semantic defaults in presentation order', () {
    expect(_snapshots(defaultAllowancesFor('claude-code')), const [
      [
        'claude-weekly-limit',
        'Claude weekly limit',
        'Claude',
        'week',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh the Claude quota.',
      ],
    ]);
    expect(_snapshots(defaultAllowancesFor('codex')), const [
      [
        'chatgpt-weekly-limit',
        'ChatGPT weekly limit',
        'ChatGPT',
        'week',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh the ChatGPT quota.',
      ],
      [
        'chatgpt-limit-reset-credits',
        'ChatGPT limit reset credits',
        'ChatGPT',
        'reset-credits',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh ChatGPT limit reset credits.',
      ],
    ]);
    expect(_snapshots(defaultAllowancesFor('antigravity')), const [
      [
        'antigravity-gemini-5h-limit',
        'Gemini 5-hour limit',
        'Gemini',
        'session',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh the Gemini 5-hour quota.',
      ],
      [
        'antigravity-gemini-weekly-limit',
        'Gemini weekly limit',
        'Gemini',
        'week',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh the Gemini quota.',
      ],
      [
        'antigravity-claude-gpt-5h-limit',
        'Claude/GPT 5-hour limit',
        'Claude/GPT',
        'session',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh the Claude/GPT 5-hour quota.',
      ],
      [
        'antigravity-claude-gpt-weekly-limit',
        'Claude/GPT weekly limit',
        'Claude/GPT',
        'week',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh the Antigravity quota.',
      ],
    ]);
    expect(_snapshots(defaultAllowancesFor('kilo-code')), const [
      [
        'kilo-pass-limit',
        'Kilo Pass',
        'Kilo Pass',
        'month',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh Kilo Pass.',
      ],
      [
        'kilo-recharge-credits',
        'Recharge credits',
        'Kilo',
        'balance',
        'unavailable',
        '',
        'credits',
        'lico-arc-pending',
        'Run usage scan to refresh Kilo recharge credits.',
      ],
    ]);
    expect(_snapshots(defaultAllowancesFor('opencode')), const [
      [
        'model-api-balance',
        'Model API balance',
        'OpenCode',
        'balance',
        'unavailable',
        '',
        '',
        'lico-arc-pending',
        'Run usage scan to refresh the OpenCode model balance.',
      ],
    ]);
  });

  test('does not normalize or invent defaults for unknown targets', () {
    expect(defaultAllowancesFor(''), isEmpty);
    expect(defaultAllowancesFor('Codex'), isEmpty);
    expect(defaultAllowancesFor(' codex '), isEmpty);
    expect(defaultAllowancesFor('unknown'), isEmpty);
  });
}

List<List<String>> _snapshots(List<AgentUsageAllowance> allowances) {
  return allowances
      .map(
        (allowance) => [
          allowance.kind,
          allowance.label,
          allowance.provider,
          allowance.period,
          allowance.status,
          allowance.value,
          allowance.unit,
          allowance.source,
          allowance.message,
        ],
      )
      .toList(growable: false);
}
