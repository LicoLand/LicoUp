enum GroupParticipantKind {
  human,
  agent;

  static GroupParticipantKind parse(String raw) {
    return raw.trim().toLowerCase() == 'agent'
        ? GroupParticipantKind.agent
        : GroupParticipantKind.human;
  }

  String toJson() => this == GroupParticipantKind.agent ? 'agent' : 'human';
}

final class GroupParticipant {
  const GroupParticipant({
    required this.id,
    required this.kind,
    required this.displayName,
    this.agentId,
  });

  final String id;
  final GroupParticipantKind kind;
  final String displayName;
  final String? agentId;

  factory GroupParticipant.fromJson(Map<String, dynamic> json) {
    return GroupParticipant(
      id: (json['id'] ?? '').toString(),
      kind: GroupParticipantKind.parse((json['kind'] ?? '').toString()),
      displayName: (json['displayName'] ?? '').toString(),
      agentId: (json['agentId'] ?? '').toString().trim().isEmpty
          ? null
          : (json['agentId'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.toJson(),
    'displayName': displayName,
    if (agentId != null && agentId!.isNotEmpty) 'agentId': agentId,
  };
}
