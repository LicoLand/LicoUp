import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/features/agents/policy/routing_circuit_breaker_registry.dart';

void main() {
  test('opens after the allowed failures and resets after cooldown', () {
    final startedAt = DateTime.utc(2026, 1, 1);
    const cooldown = Duration(seconds: 30);
    final first = RoutingCircuitBreakerRegistry.recordFailure(
      const {},
      'codex',
      allowedFails: 1,
      cooldown: cooldown,
      now: startedAt,
    );
    final second = RoutingCircuitBreakerRegistry.recordFailure(
      first.states,
      'codex',
      allowedFails: 1,
      cooldown: cooldown,
      now: startedAt.add(const Duration(seconds: 1)),
    );

    expect(first.isOpen, isFalse);
    expect(second.isOpen, isTrue);

    final afterCooldown = RoutingCircuitBreakerRegistry.recordFailure(
      second.states,
      'codex',
      allowedFails: 1,
      cooldown: cooldown,
      now: startedAt.add(const Duration(seconds: 32)),
    );
    expect(afterCooldown.isOpen, isFalse);
    expect(afterCooldown.states['codex']?.failureCount, 1);
  });

  test('success and policy changes prune only selected agents', () {
    final now = DateTime.utc(2026, 1, 1);
    final codex = RoutingCircuitBreakerRegistry.recordFailure(
      const {},
      'codex',
      allowedFails: 0,
      cooldown: const Duration(minutes: 1),
      now: now,
    );
    final claude = RoutingCircuitBreakerRegistry.recordFailure(
      codex.states,
      'claude',
      allowedFails: 0,
      cooldown: const Duration(minutes: 1),
      now: now,
    );

    final retained = RoutingCircuitBreakerRegistry.retainAgents(claude.states, {
      'codex',
    });
    expect(retained.keys, ['codex']);
    expect(
      RoutingCircuitBreakerRegistry.recordSuccess(retained, 'codex'),
      isEmpty,
    );
  });
}
