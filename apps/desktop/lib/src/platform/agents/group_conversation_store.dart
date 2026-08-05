import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

const defaultLicoGroupConversationId = 'lico-group-default';

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

enum TurnTakingPolicy {
  flywheelMainDispatch,
  mentionOnly,
  parallelSelected;

  static TurnTakingPolicy parse(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'mention-only' => TurnTakingPolicy.mentionOnly,
      'parallel-selected' => TurnTakingPolicy.parallelSelected,
      _ => TurnTakingPolicy.flywheelMainDispatch,
    };
  }

  String toJson() => switch (this) {
    TurnTakingPolicy.flywheelMainDispatch => 'flywheel-main-dispatch',
    TurnTakingPolicy.mentionOnly => 'mention-only',
    TurnTakingPolicy.parallelSelected => 'parallel-selected',
  };
}

enum PlannedTurnRole {
  dispatcher,
  peer;

  String toJson() => this == PlannedTurnRole.dispatcher ? 'dispatcher' : 'peer';
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

final class GroupRoster {
  const GroupRoster({this.participants = const [], this.mainAgentId});

  final List<GroupParticipant> participants;
  final String? mainAgentId;

  static const empty = GroupRoster();

  bool containsAgent(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) return false;
    return participants.any(
      (participant) =>
          participant.kind == GroupParticipantKind.agent &&
          participant.agentId == normalized,
    );
  }

  GroupRoster upsertAgent(String agentId, String displayName) {
    if (containsAgent(agentId)) return this;
    return GroupRoster(
      participants: [
        ...participants,
        GroupParticipant(
          id: 'agent:$agentId',
          kind: GroupParticipantKind.agent,
          displayName: displayName,
          agentId: agentId,
        ),
      ],
      mainAgentId: mainAgentId,
    );
  }

  GroupRoster ensureHuman(String displayName) {
    if (participants.any(
      (participant) => participant.kind == GroupParticipantKind.human,
    )) {
      return this;
    }
    return GroupRoster(
      participants: [
        GroupParticipant(
          id: 'human:local',
          kind: GroupParticipantKind.human,
          displayName: displayName,
        ),
        ...participants,
      ],
      mainAgentId: mainAgentId,
    );
  }

  GroupRoster copyWithMainAgent(String? agentId) {
    final normalized = agentId?.trim() ?? '';
    return GroupRoster(
      participants: participants,
      mainAgentId: normalized.isEmpty ? null : normalized,
    );
  }

  factory GroupRoster.fromJson(Map<String, dynamic> json) {
    final rawParticipants = json['participants'];
    return GroupRoster(
      participants: rawParticipants is List
          ? [
              for (final entry in rawParticipants)
                if (entry is Map<String, dynamic>)
                  GroupParticipant.fromJson(entry),
            ]
          : const [],
      mainAgentId: (json['mainAgentId'] ?? '').toString().trim().isEmpty
          ? null
          : (json['mainAgentId'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'participants': [
      for (final participant in participants) participant.toJson(),
    ],
    if (mainAgentId != null && mainAgentId!.isNotEmpty)
      'mainAgentId': mainAgentId,
  };
}

final class GroupConversationRecord {
  const GroupConversationRecord({
    required this.id,
    required this.title,
    required this.roster,
    required this.turnTaking,
    required this.transcriptPath,
  });

  final String id;
  final String title;
  final GroupRoster roster;
  final TurnTakingPolicy turnTaking;
  final String transcriptPath;

  factory GroupConversationRecord.fromJson(Map<String, dynamic> json) {
    return GroupConversationRecord(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      roster: json['roster'] is Map<String, dynamic>
          ? GroupRoster.fromJson(json['roster'] as Map<String, dynamic>)
          : GroupRoster.empty,
      turnTaking: TurnTakingPolicy.parse((json['turnTaking'] ?? '').toString()),
      transcriptPath: (json['transcriptPath'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'roster': roster.toJson(),
    'turnTaking': turnTaking.toJson(),
    'transcriptPath': transcriptPath,
  };
}

final class PlannedAgentTurn {
  const PlannedAgentTurn({required this.agentId, required this.role});

  final String agentId;
  final PlannedTurnRole role;
}

final class GroupConversationStore {
  GroupConversationStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _recordFileName =
      'group-conversations/$defaultLicoGroupConversationId.json';

  final MobileRelayJsonStore _jsonStore;

  Future<GroupConversationRecord?> load(Object portableData) async {
    final decoded = await _jsonStore.read(portableData, _recordFileName);
    if (decoded is! Map) return null;
    return GroupConversationRecord.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<void> save(Object portableData, GroupConversationRecord record) async {
    await _jsonStore.write(
      portableData,
      _recordFileName,
      record.toJson(),
      lock: true,
    );
  }

  Future<GroupConversationRecord> ensureDefaultLicoRoom(
    Object portableData,
  ) async {
    final existing = await load(portableData);
    if (existing != null) return existing;
    if (portableData is! PortableDataRoot) {
      throw ArgumentError.value(portableData, 'portableData');
    }
    final dataDir = await portableData.dataDirectory();
    final transcriptDir = Directory(
      p.join(
        dataDir.path,
        'client-state',
        'group-conversations',
        'transcripts',
      ),
    );
    await transcriptDir.create(recursive: true);
    final transcriptPath = p.join(
      transcriptDir.path,
      '$defaultLicoGroupConversationId.jsonl',
    );
    final transcriptFile = File(transcriptPath);
    if (!await transcriptFile.exists()) {
      await transcriptFile.writeAsString('');
    }
    final record = GroupConversationRecord(
      id: defaultLicoGroupConversationId,
      title: 'Lico',
      roster: GroupRoster.empty.ensureHuman('You'),
      turnTaking: TurnTakingPolicy.flywheelMainDispatch,
      transcriptPath: transcriptPath,
    );
    await save(portableData, record);
    return record;
  }

  Future<GroupConversationRecord> syncRosterFromFlywheel({
    required Object portableData,
    required String mainAgentId,
    required List<({String id, String label})> agents,
  }) async {
    final room = await ensureDefaultLicoRoom(portableData);
    final human = room.roster.participants
        .where((p) => p.kind == GroupParticipantKind.human)
        .toList(growable: false);
    final participants = <GroupParticipant>[
      if (human.isEmpty)
        const GroupParticipant(
          id: 'human:local',
          kind: GroupParticipantKind.human,
          displayName: 'You',
        )
      else
        ...human,
    ];
    final seen = <String>{};
    for (final agent in agents) {
      final id = agent.id.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      participants.add(
        GroupParticipant(
          id: 'agent:$id',
          kind: GroupParticipantKind.agent,
          displayName: agent.label.trim().isEmpty ? id : agent.label.trim(),
          agentId: id,
        ),
      );
    }
    final updated = GroupConversationRecord(
      id: room.id,
      title: room.title,
      roster: GroupRoster(
        participants: participants,
        mainAgentId: mainAgentId.trim().isEmpty ? null : mainAgentId.trim(),
      ),
      turnTaking: room.turnTaking,
      transcriptPath: room.transcriptPath,
    );
    await save(portableData, updated);
    return updated;
  }

  static List<PlannedAgentTurn> planTurn({
    required GroupRoster roster,
    required String userText,
    TurnTakingPolicy policy = TurnTakingPolicy.flywheelMainDispatch,
    List<String> selectedAgentIds = const [],
  }) {
    switch (policy) {
      case TurnTakingPolicy.flywheelMainDispatch:
        final main = roster.mainAgentId?.trim() ?? '';
        if (main.isEmpty) return const [];
        final planned = <PlannedAgentTurn>[
          PlannedAgentTurn(agentId: main, role: PlannedTurnRole.dispatcher),
        ];
        for (final participant in roster.participants) {
          if (participant.kind != GroupParticipantKind.agent) continue;
          final agentId = participant.agentId?.trim() ?? '';
          if (agentId.isEmpty || agentId == main) continue;
          planned.add(
            PlannedAgentTurn(agentId: agentId, role: PlannedTurnRole.peer),
          );
        }
        return planned;
      case TurnTakingPolicy.mentionOnly:
      case TurnTakingPolicy.parallelSelected:
        return [
          for (final agentId in selectedAgentIds)
            if (roster.containsAgent(agentId))
              PlannedAgentTurn(agentId: agentId, role: PlannedTurnRole.peer),
        ];
    }
  }
}
