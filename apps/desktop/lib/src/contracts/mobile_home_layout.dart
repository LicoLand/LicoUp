class MobileHomeLayout {
  const MobileHomeLayout({
    this.order = const [],
    this.pinnedEntryIds = const {},
  });

  static const currentSchemaVersion = 1;

  final List<String> order;
  final Set<String> pinnedEntryIds;

  static MobileHomeLayout defaults() => const MobileHomeLayout();

  bool isPinned(String entryId) => pinnedEntryIds.contains(entryId);

  MobileHomeLayout copyWith({
    List<String>? order,
    Set<String>? pinnedEntryIds,
  }) {
    return MobileHomeLayout(
      order: List.unmodifiable(order ?? this.order),
      pinnedEntryIds: Set.unmodifiable(pinnedEntryIds ?? this.pinnedEntryIds),
    );
  }

  factory MobileHomeLayout.fromJson(Map<String, dynamic> json) {
    final rawOrder = json['order'];
    final rawPinned = json['pinnedEntryIds'];
    return MobileHomeLayout(
      order: rawOrder is List
          ? List.unmodifiable(
              rawOrder.map((item) => item.toString()).where(_validEntryId),
            )
          : const [],
      pinnedEntryIds: rawPinned is List
          ? Set.unmodifiable(
              rawPinned.map((item) => item.toString()).where(_validEntryId),
            )
          : const {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': currentSchemaVersion,
      'order': order,
      'pinnedEntryIds': pinnedEntryIds.toList()..sort(),
    };
  }

  static bool _validEntryId(String value) {
    return value.trim().isNotEmpty && value.contains(':');
  }
}

abstract class MobileHomeLayoutStore {
  const MobileHomeLayoutStore();

  Future<Object?> read(Object portableData);
  Future<void> write(Object portableData, Object? payload);
}
