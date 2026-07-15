import 'package:flutter_client/src/contracts/mobile_provider_conversation.dart';

class MobileProviderConversationService {
  const MobileProviderConversationService({
    required MobileProviderConversationStore store,
  }) : _store = store;

  static const currentSchemaVersion = 1;
  static const trashRetention = Duration(days: 30);
  final MobileProviderConversationStore _store;

  Future<List<MobileProviderConversationRecord>> load(
    Object portableData, {
    DateTime? now,
  }) async {
    final decoded = await _store.read(portableData);
    if (decoded == null) {
      return const [];
    }
    final rawRecords = decoded is Map ? decoded['conversations'] : decoded;
    final recordsJson = rawRecords is List ? rawRecords : const [];
    final records = <MobileProviderConversationRecord>[];
    for (final item in recordsJson) {
      if (item is! Map) {
        continue;
      }
      final MobileProviderConversationRecord record;
      try {
        record = MobileProviderConversationRecord.fromJson(
          Map<String, dynamic>.from(item),
        );
      } on Object {
        continue;
      }
      if (record.accountId.trim().isEmpty ||
          record.providerId.trim().isEmpty ||
          record.session.id.trim().isEmpty) {
        continue;
      }
      records.add(record);
    }
    final purged = purgeExpiredTrash(records, now: now);
    if (purged.length != records.length) {
      await save(portableData, purged);
    }
    return List<MobileProviderConversationRecord>.unmodifiable(
      _sortRecords(purged),
    );
  }

  Future<void> save(
    Object portableData,
    List<MobileProviderConversationRecord> records,
  ) async {
    await _store.write(portableData, {
      'schemaVersion': currentSchemaVersion,
      'conversations': _sortRecords(
        records,
      ).map((record) => record.toJson()).toList(),
    });
  }

  List<MobileProviderConversationRecord> purgeExpiredTrash(
    List<MobileProviderConversationRecord> records, {
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(trashRetention);
    return List<MobileProviderConversationRecord>.unmodifiable(
      records.where((record) {
        if (!record.isTrashed) {
          return true;
        }
        final deletedAt = DateTime.tryParse(record.deletedAt)?.toUtc();
        if (deletedAt == null) {
          return true;
        }
        return deletedAt.isAfter(cutoff);
      }),
    );
  }
}

List<MobileProviderConversationRecord> _sortRecords(
  List<MobileProviderConversationRecord> records,
) {
  final sorted = [...records];
  sorted.sort((left, right) {
    final rightTime = _recordSortTime(right);
    final leftTime = _recordSortTime(left);
    if (rightTime != leftTime) {
      return rightTime.compareTo(leftTime);
    }
    return right.session.id.compareTo(left.session.id);
  });
  return sorted;
}

int _recordSortTime(MobileProviderConversationRecord record) {
  return DateTime.tryParse(record.session.updatedAt)?.millisecondsSinceEpoch ??
      DateTime.tryParse(record.session.createdAt)?.millisecondsSinceEpoch ??
      0;
}
