final class AgentConversationMessagePage {
  const AgentConversationMessagePage({
    required this.start,
    required this.endExclusive,
    required this.returned,
    required this.total,
    required this.hasEarlier,
    required this.nextBefore,
  });

  const AgentConversationMessagePage.empty()
    : start = 0,
      endExclusive = 0,
      returned = 0,
      total = 0,
      hasEarlier = false,
      nextBefore = '';

  final int start;
  final int endExclusive;
  final int returned;
  final int total;
  final bool hasEarlier;
  final String nextBefore;

  factory AgentConversationMessagePage.fromJson(
    Object? raw, {
    required int messageCount,
    required int sourceMessageCount,
    required String firstMessageId,
  }) {
    if (raw == null) {
      final total = sourceMessageCount < messageCount
          ? messageCount
          : sourceMessageCount;
      final start = total - messageCount;
      return AgentConversationMessagePage(
        start: start,
        endExclusive: total,
        returned: messageCount,
        total: total,
        hasEarlier: start > 0,
        nextBefore: start > 0 ? firstMessageId : '',
      );
    }
    if (raw is! Map) {
      throw const FormatException('native_history_message_page_invalid');
    }
    final page = Map<String, dynamic>.from(raw);
    int integer(String key) => switch (page[key]) {
      final int value => value,
      final num value => value.toInt(),
      _ => -1,
    };
    final start = integer('start');
    final endExclusive = integer('endExclusive');
    final returned = integer('returned');
    final total = integer('total');
    final hasEarlier = page['hasEarlier'];
    final nextBefore = (page['nextBefore'] ?? '').toString().trim();
    if (start < 0 ||
        endExclusive < start ||
        returned < 0 ||
        total < endExclusive ||
        returned != messageCount ||
        endExclusive - start != returned ||
        hasEarlier is! bool ||
        (hasEarlier && (start == 0 || nextBefore.isEmpty)) ||
        (!hasEarlier && start != 0)) {
      throw const FormatException('native_history_message_page_invalid');
    }
    return AgentConversationMessagePage(
      start: start,
      endExclusive: endExclusive,
      returned: returned,
      total: total,
      hasEarlier: hasEarlier,
      nextBefore: hasEarlier ? nextBefore : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'start': start,
    'endExclusive': endExclusive,
    'returned': returned,
    'total': total,
    'hasEarlier': hasEarlier,
    if (nextBefore.isNotEmpty) 'nextBefore': nextBefore,
  };
}
