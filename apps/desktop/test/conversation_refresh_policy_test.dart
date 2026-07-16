import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/features/agents/policy/conversation_refresh_policy.dart';

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
}
