import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/policy/conversation_refresh_policy.dart';

void main() {
  test('maps every refresh priority to its bounded interval', () {
    const policy = ConversationRefreshPolicy(
      activeInterval: Duration(seconds: 1),
      warmInterval: Duration(seconds: 2),
      backgroundInterval: Duration(seconds: 3),
      activeCatalogInterval: Duration(seconds: 4),
      warmCatalogInterval: Duration(seconds: 5),
      backgroundCatalogInterval: Duration(seconds: 6),
    );

    expect(
      policy.activeDelay(ConversationRefreshPriority.active),
      const Duration(seconds: 1),
    );
    expect(
      policy.activeDelay(ConversationRefreshPriority.warm),
      const Duration(seconds: 2),
    );
    expect(
      policy.activeDelay(ConversationRefreshPriority.background),
      const Duration(seconds: 3),
    );
    expect(
      policy.catalogDelay(ConversationRefreshPriority.active),
      const Duration(seconds: 4),
    );
    expect(
      policy.catalogDelay(ConversationRefreshPriority.warm),
      const Duration(seconds: 5),
    );
    expect(
      policy.catalogDelay(ConversationRefreshPriority.background),
      const Duration(seconds: 6),
    );
    expect(
      policy.activeDelay(ConversationRefreshPriority.suspended),
      Duration.zero,
    );
    expect(
      policy.catalogDelay(ConversationRefreshPriority.suspended),
      Duration.zero,
    );
  });

  test('the active lane doubles while quiet and caps at its catalog delay', () {
    const policy = ConversationRefreshPolicy(
      activeInterval: Duration(seconds: 2),
      activeCatalogInterval: Duration(seconds: 20),
      warmCatalogInterval: Duration(seconds: 45),
    );

    final active = ConversationRefreshPriority.active;
    expect(policy.activeDelayAfter(active, 0), const Duration(seconds: 2));
    expect(policy.activeDelayAfter(active, 1), const Duration(seconds: 4));
    expect(policy.activeDelayAfter(active, 2), const Duration(seconds: 8));
    expect(policy.activeDelayAfter(active, 3), const Duration(seconds: 16));
    expect(policy.activeDelayAfter(active, 4), const Duration(seconds: 20));
    expect(policy.activeDelayAfter(active, 9), const Duration(seconds: 20));
    expect(
      policy.activeDelayAfter(active, 40),
      const Duration(seconds: 20),
      reason: 'the counter is clamped so overflow can never widen the delay',
    );

    final warm = ConversationRefreshPriority.warm;
    expect(policy.activeDelayAfter(warm, 0), const Duration(seconds: 10));
    expect(policy.activeDelayAfter(warm, 2), const Duration(seconds: 40));
    expect(
      policy.activeDelayAfter(warm, 3),
      const Duration(seconds: 45),
      reason: 'warm caps at the warm catalog interval, not the active one',
    );

    expect(
      policy.activeDelayAfter(ConversationRefreshPriority.suspended, 3),
      Duration.zero,
    );
  });
}
