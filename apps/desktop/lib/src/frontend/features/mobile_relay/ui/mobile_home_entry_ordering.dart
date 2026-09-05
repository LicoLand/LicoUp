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
  List<MobileHomeEntryOrderItem> entries, {
  required List<String> persistedOrder,
}) {
  final orderIndex = <String, int>{
    for (var index = 0; index < persistedOrder.length; index += 1)
      persistedOrder[index]: index,
  };
  final indexed = entries.indexed.toList(growable: false);
  indexed.sort((left, right) {
    final pinnedCompare = (left.$2.pinned ? 0 : 1).compareTo(
      right.$2.pinned ? 0 : 1,
    );
    if (pinnedCompare != 0) return pinnedCompare;
    if (left.$2.pinned) {
      final leftOrder =
          orderIndex[left.$2.id] ?? (persistedOrder.length + left.$1);
      final rightOrder =
          orderIndex[right.$2.id] ?? (persistedOrder.length + right.$1);
      return leftOrder.compareTo(rightOrder);
    }
    final timeCompare = right.$2.sortTimeMillis.compareTo(
      left.$2.sortTimeMillis,
    );
    return timeCompare != 0 ? timeCompare : left.$1.compareTo(right.$1);
  });
  return List<String>.unmodifiable(indexed.map((item) => item.$2.id));
}

String mobileHomePreviewText(String? value) {
  return (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
}
