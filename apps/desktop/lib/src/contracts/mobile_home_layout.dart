class MobileHomeLayout {
  const MobileHomeLayout({
    this.order = const [],
    this.pinnedEntryIds = const {},
  });

  static const currentSchemaVersion = 2;

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
    if ((json['schemaVersion'] as num?)?.toInt() != currentSchemaVersion) {
      return defaults();
    }
    final rawOrder = json['order'];
    final rawPinned = json['pinnedEntryIds'];
    return MobileHomeLayout(
      order: rawOrder is List
          ? List.unmodifiable(
              rawOrder.map((item) => item.toString()).where(isSupportedEntryId),
            )
          : const [],
      pinnedEntryIds: rawPinned is List
          ? Set.unmodifiable(
              rawPinned
                  .map((item) => item.toString())
                  .where(isSupportedEntryId),
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

  static bool isSupportedEntryId(String value) {
    final normalized = value.trim();
    return (normalized.startsWith('target:') && normalized.length > 7) ||
        (normalized.startsWith('device:') && normalized.length > 7);
  }
}

abstract class MobileHomeLayoutStore {
  const MobileHomeLayoutStore();

  Future<Object?> read(Object portableData);
  Future<void> write(Object portableData, Object? payload);
}
