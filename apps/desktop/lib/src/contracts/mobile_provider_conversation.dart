import 'package:flutter_client/src/contracts/agent_conversation_models.dart';

const mobileProviderConversationStatusActive = 'active';
const mobileProviderConversationStatusArchived = 'archived';
const mobileProviderConversationStatusTrashed = 'trashed';

class MobileProviderConversationRecord {
  const MobileProviderConversationRecord({
    required this.accountId,
    required this.providerId,
    required this.status,
    required this.session,
    this.deletedAt = '',
    this.archivedAt = '',
  });

  final String accountId;
  final String providerId;
  final String status;
  final String deletedAt;
  final String archivedAt;
  final AgentConversationSession session;

  bool get isActive => status == mobileProviderConversationStatusActive;
  bool get isArchived => status == mobileProviderConversationStatusArchived;
  bool get isTrashed => status == mobileProviderConversationStatusTrashed;

  MobileProviderConversationRecord copyWith({
    String? status,
    String? deletedAt,
    String? archivedAt,
    AgentConversationSession? session,
  }) {
    return MobileProviderConversationRecord(
      accountId: accountId,
      providerId: providerId,
      status: status ?? this.status,
      deletedAt: deletedAt ?? this.deletedAt,
      archivedAt: archivedAt ?? this.archivedAt,
      session: session ?? this.session,
    );
  }

  factory MobileProviderConversationRecord.fromJson(Map<String, dynamic> json) {
    return MobileProviderConversationRecord(
      accountId: (json['accountId'] ?? '').toString(),
      providerId: (json['providerId'] ?? '').toString(),
      status: _normalizeStatus((json['status'] ?? '').toString()),
      deletedAt: (json['deletedAt'] ?? '').toString(),
      archivedAt: (json['archivedAt'] ?? '').toString(),
      session: AgentConversationSession.fromJson(
        Map<String, dynamic>.from(json['session'] as Map? ?? const {}),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accountId': accountId,
      'providerId': providerId,
      'status': status,
      if (deletedAt.trim().isNotEmpty) 'deletedAt': deletedAt,
      if (archivedAt.trim().isNotEmpty) 'archivedAt': archivedAt,
      'session': session.toJson(),
    };
  }
}

String _normalizeStatus(String value) {
  final normalized = value.trim().toLowerCase();
  return switch (normalized) {
    mobileProviderConversationStatusArchived =>
      mobileProviderConversationStatusArchived,
    mobileProviderConversationStatusTrashed =>
      mobileProviderConversationStatusTrashed,
    _ => mobileProviderConversationStatusActive,
  };
}

abstract class MobileProviderConversationStore {
  const MobileProviderConversationStore();

  Future<Object?> read(Object portableData);
  Future<void> write(Object portableData, Object? payload);
}
