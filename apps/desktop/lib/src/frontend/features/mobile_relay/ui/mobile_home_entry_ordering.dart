import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout.dart';

final class MobileHomeEntryOrderItem {
  const MobileHomeEntryOrderItem({
    required this.id,
    required this.pinned,
    required this.sortTimeMillis,
  });

  final String id;
  final bool pinned;
  final int sortTimeMillis;
}

List<String> orderMobileHomeEntryIds(
  List<MobileHomeEntryOrderItem> entries,
  MobileHomeLayout layout,
) {
  final orderIndex = <String, int>{
    for (var index = 0; index < layout.order.length; index++)
      layout.order[index]: index,
  };
  final indexed = entries.indexed.toList(growable: false);
  indexed.sort((left, right) {
    final pinnedCompare = (left.$2.pinned ? 0 : 1).compareTo(
      right.$2.pinned ? 0 : 1,
    );
    if (pinnedCompare != 0) return pinnedCompare;
    if (left.$2.pinned) {
      final leftOrder =
          orderIndex[left.$2.id] ?? (layout.order.length + left.$1);
      final rightOrder =
          orderIndex[right.$2.id] ?? (layout.order.length + right.$1);
      return leftOrder.compareTo(rightOrder);
    }
    final timeCompare = right.$2.sortTimeMillis.compareTo(
      left.$2.sortTimeMillis,
    );
    return timeCompare != 0 ? timeCompare : left.$1.compareTo(right.$1);
  });
  return List.unmodifiable(indexed.map((item) => item.$2.id));
}

AgentConversationSession? latestMobileHomeSession(
  List<AgentConversationSession> sessions,
) {
  AgentConversationSession? latest;
  for (final session in sessions) {
    if (latest == null ||
        mobileConversationSortTime(session) >
            mobileConversationSortTime(latest)) {
      latest = session;
    }
  }
  return latest;
}

int mobileConversationSortTime(AgentConversationSession session) {
  return parseMobileHomeSortTime(session.updatedAt, session.createdAt);
}

int parseMobileHomeSortTime(String primary, [String fallback = '']) {
  return (DateTime.tryParse(primary) ??
          DateTime.tryParse(fallback) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
      .toUtc()
      .millisecondsSinceEpoch;
}

String mobileHomePreviewText(String? value) {
  return (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
}
