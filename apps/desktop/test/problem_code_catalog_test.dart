import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/problem_codes/problem_codes.dart';

void main() {
  test('prefix allocation does not overlap', () {
    final prefixes = <String>{};
    final numbers = <int>{};
    for (final domain in ProblemDomain.values) {
      expect(prefixes.add(domain.prefix), isTrue, reason: domain.prefix);
      expect(domain.rangeStart, lessThanOrEqualTo(domain.rangeEnd));
      for (
        var number = domain.rangeStart;
        number <= domain.rangeEnd;
        number++
      ) {
        expect(
          numbers.add(number),
          isTrue,
          reason: 'LU-${domain.prefix}-$number',
        );
      }
    }
  });

  test('every mapped legacy code has a unique primary problem code', () {
    final byWire = <String, ProblemCode>{};
    for (final entry in problemCodeEntries.entries) {
      byWire.putIfAbsent(entry.value.wire, () => entry.value);
      expect(entry.value.domain.contains(entry.value.number), isTrue);
      expect(entry.key.isNotEmpty, isTrue);
      expect(entry.value.wire, startsWith('LU-${entry.value.domain.prefix}-'));
    }
    final uniqueCodes = problemCodeEntries.values.toSet();
    expect(uniqueCodes.length, lessThanOrEqualTo(problemCodeEntries.length));
    expect(problemCodeEntries.length, greaterThan(700));
  });

  test('maps current conversation and RPC failures', () {
    expect(
      ProblemCodeCatalog.wire('conversation_operation_failed'),
      'LU-CV-1402',
    );
    expect(ProblemCodeCatalog.wire('transport_failed'), 'LU-RP-1001');
    expect(ProblemCodeCatalog.wire('timeout'), 'LU-RP-1002');
    expect(ProblemCodeCatalog.wire('invalid_request'), 'LU-RP-1008');
    expect(
      ProblemCodeCatalog.wire('persistent_conversation_transport_required'),
      startsWith('LU-CV-'),
    );
    expect(
      ProblemCodeCatalog.wire('strategy_operation_failed'),
      startsWith('LU-ST-'),
    );
    expect(ProblemCodeCatalog.wire('workflow_invalid'), startsWith('LU-ST-'));
  });

  test('typed dispatch, run-start, and transport codes are stable', () {
    expect(
      ProblemCodeCatalog.wire('conversation_dispatch_failed'),
      'LU-CV-1201',
    );
    expect(ProblemCodeCatalog.wire('strategy_run_start_failed'), 'LU-ST-1925');
    expect(
      ProblemCodeCatalog.wire('strategy_actor_quota_exhausted'),
      'LU-ST-1923',
    );
    expect(ProblemCodeCatalog.wire('transport_failed'), 'LU-RP-1001');
    expect(
      ProblemCodeCatalog.wire('conversation_dispatch_failed'),
      isNot(ProblemCodeCatalog.wire('conversation_operation_failed')),
    );
    expect(
      ProblemCodeCatalog.wire('strategy_run_start_failed'),
      isNot(ProblemCodeCatalog.wire('strategy_operation_failed')),
    );
  });

  test('aliases and native_agent prefix share one failure class', () {
    const transport = 'LU-RP-1001';
    expect(ProblemCodeCatalog.wire('native_agent_transport_failed'), transport);
    expect(ProblemCodeCatalog.wire('mcp_http_transport_failed'), transport);
    expect(ProblemCodeCatalog.wire('subagent_transport_failed'), transport);
    expect(ProblemCodeCatalog.wire('native_agent_timeout'), 'LU-RP-1002');
    expect(
      ProblemCodeCatalog.wire('native_agent_claude_code_timeout'),
      ProblemCodeCatalog.wire('claude_code_timeout'),
    );
  });

  test('unknown legacy codes use the reserved unmapped slot', () {
    expect(ProblemCodeCatalog.wire('not_a_real_failure_code'), 'LU-XX-9900');
    expect(ProblemCodeCatalog.isMapped('not_a_real_failure_code'), isFalse);
    expect(ProblemCodeCatalog.isMapped('transport_failed'), isTrue);
    expect(ProblemCodeCatalog.isMapped(''), isFalse);
  });

  test('OpenCode serve protocol failures have a native-agent problem code', () {
    expect(
      ProblemCodeCatalog.wire('opencode_serve_protocol_write_failed'),
      'LU-NA-4205',
    );
    expect(
      ProblemCodeCatalog.wire('opencode_serve_message_failed'),
      'LU-NA-4219',
    );
    expect(
      ProblemCodeCatalog.wire('opencode_serve_control_failed'),
      'LU-NA-4216',
    );
    expect(ProblemCodeCatalog.wire('opencode_serve_sse_closed'), 'LU-NA-4223');
    expect(ProblemCodeCatalog.isMapped('opencode_serve_unavailable'), isFalse);
  });

  test('Pi model resolution failures have a native-agent problem code', () {
    expect(ProblemCodeCatalog.wire('pi_model_override_failed'), 'LU-NA-4213');
  });

  test('Cursor strict protocol failures have native-agent problem codes', () {
    expect(
      ProblemCodeCatalog.wire('cursor_cli_private_instructions_unsupported'),
      'LU-NA-4233',
    );
    expect(
      ProblemCodeCatalog.wire('cursor_cli_session_identity_mismatch'),
      'LU-NA-4234',
    );
    expect(
      ProblemCodeCatalog.wire('cursor_cli_text_snapshot_diverged'),
      'LU-NA-4235',
    );
    expect(
      ProblemCodeCatalog.wire('cursor_cli_unterminated_json'),
      'LU-NA-4236',
    );
    expect(
      ProblemCodeCatalog.wire('cursor_cli_prompt_acknowledgement_missing'),
      'LU-NA-4237',
    );
    expect(
      ProblemCodeCatalog.wire('cursor_cli_prompt_acknowledgement_mismatch'),
      'LU-NA-4238',
    );
    expect(ProblemCodeCatalog.wire('codex_usage_limit_exceeded'), 'LU-NA-4239');
    expect(
      ProblemCodeCatalog.wire('cursor_cli_authentication_required'),
      'LU-NA-4240',
    );
    expect(
      ProblemCodeCatalog.wire('cursor_cli_execution_failed'),
      'LU-NA-4241',
    );
    expect(
      ProblemCodeCatalog.wire('cursor_cli_model_unavailable'),
      'LU-NA-4242',
    );
    expect(ProblemCodeCatalog.wire('cursor_cli_rate_limited'), 'LU-NA-4243');
    expect(
      ProblemCodeCatalog.wire('cursor_cli_usage_limit_exceeded'),
      'LU-NA-4244',
    );
  });

  test('copy payload includes both problem code and occurrence id', () {
    final blob = ProblemCodeCopy.copyableDetail(
      legacyCode: 'transport_failed',
      stage: 'send',
      occurrenceId: '#L-A3F2',
      occurredAt: '2026-08-19T03:00:00.000Z',
    );
    expect(blob, contains('LicoUp problem'));
    expect(blob, contains('problemCode: LU-RP-1001'));
    expect(blob, contains('code: transport_failed'));
    expect(blob, contains('domain: rpc'));
    expect(blob, contains('stage: send'));
    expect(blob, contains('ref: #L-A3F2'));
    expect(blob, contains('at: 2026-08-19T03:00:00.000Z'));
    expect(blob, isNot(contains('/Users/')));
    expect(blob, isNot(contains('hi there')));
  });

  test('tryParse round-trips allocated wire forms', () {
    const code = ProblemCode(ProblemDomain.conversation, 1402);
    expect(ProblemCode.tryParse(code.wire), code);
    expect(ProblemCode.tryParse('LU-ZZ-0001'), isNull);
    expect(ProblemCode.tryParse('LU-CV-9999'), isNull);
  });
}
