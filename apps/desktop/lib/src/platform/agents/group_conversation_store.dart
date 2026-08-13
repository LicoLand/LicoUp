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

/// Last native conversation bound to one agent inside a Lico group room.
final class GroupAgentSessionBinding {
  const GroupAgentSessionBinding({
    required this.agentId,
    this.nativeSessionId = '',
    this.sourcePath = '',
    this.workingDirectory = '',
    this.updatedAtUnixMs = 0,
  });

  final String agentId;
  final String nativeSessionId;
  final String sourcePath;
  final String workingDirectory;
  final int updatedAtUnixMs;

  bool get hasResumeHandle =>
      nativeSessionId.trim().isNotEmpty || sourcePath.trim().isNotEmpty;

  factory GroupAgentSessionBinding.fromJson(Map<String, dynamic> json) {
    return GroupAgentSessionBinding(
      agentId: (json['agentId'] ?? '').toString().trim(),
      nativeSessionId: (json['nativeSessionId'] ?? '').toString().trim(),
      sourcePath: (json['sourcePath'] ?? '').toString().trim(),
      workingDirectory: (json['workingDirectory'] ?? '').toString().trim(),
      updatedAtUnixMs: (json['updatedAtUnixMs'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'agentId': agentId,
    if (nativeSessionId.isNotEmpty) 'nativeSessionId': nativeSessionId,
    if (sourcePath.isNotEmpty) 'sourcePath': sourcePath,
    if (workingDirectory.isNotEmpty) 'workingDirectory': workingDirectory,
    'updatedAtUnixMs': updatedAtUnixMs,
  };

  GroupAgentSessionBinding copyWith({
    String? nativeSessionId,
    String? sourcePath,
    String? workingDirectory,
    int? updatedAtUnixMs,
  }) {
    return GroupAgentSessionBinding(
      agentId: agentId,
      nativeSessionId: nativeSessionId ?? this.nativeSessionId,
      sourcePath: sourcePath ?? this.sourcePath,
      workingDirectory: workingDirectory ?? this.workingDirectory,
      updatedAtUnixMs: updatedAtUnixMs ?? this.updatedAtUnixMs,
    );
  }
}

final class GroupConversationRecord {
  const GroupConversationRecord({
    required this.id,
    required this.title,
    required this.roster,
    required this.turnTaking,
    required this.transcriptPath,
    this.agentSessions = const {},
    this.lastLocalOrchestrationSessionId = '',
  });

  final String id;
  final String title;
  final GroupRoster roster;
  final TurnTakingPolicy turnTaking;
  final String transcriptPath;

  /// Last returned native conversations for main/sub agents in this room.
  final Map<String, GroupAgentSessionBinding> agentSessions;

  /// Lico-owned orchestration projection session id last used in this room.
  final String lastLocalOrchestrationSessionId;

  GroupAgentSessionBinding? bindingFor(String agentId) {
    final id = agentId.trim();
    if (id.isEmpty) return null;
    return agentSessions[id];
  }

  factory GroupConversationRecord.fromJson(Map<String, dynamic> json) {
    final rawSessions = json['agentSessions'];
    final sessions = <String, GroupAgentSessionBinding>{};
    if (rawSessions is Map) {
      for (final entry in rawSessions.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value;
        if (key.isEmpty || value is! Map) continue;
        final parsed = GroupAgentSessionBinding.fromJson(
          Map<String, dynamic>.from(value),
        );
        final agentId = parsed.agentId.isEmpty ? key : parsed.agentId;
        if (agentId.isEmpty) continue;
        sessions[agentId] = GroupAgentSessionBinding(
          agentId: agentId,
          nativeSessionId: parsed.nativeSessionId,
          sourcePath: parsed.sourcePath,
          workingDirectory: parsed.workingDirectory,
          updatedAtUnixMs: parsed.updatedAtUnixMs,
        );
      }
    }
    return GroupConversationRecord(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      roster: json['roster'] is Map<String, dynamic>
          ? GroupRoster.fromJson(json['roster'] as Map<String, dynamic>)
          : GroupRoster.empty,
      turnTaking: TurnTakingPolicy.parse((json['turnTaking'] ?? '').toString()),
      transcriptPath: (json['transcriptPath'] ?? '').toString(),
      agentSessions: sessions,
      lastLocalOrchestrationSessionId:
          (json['lastLocalOrchestrationSessionId'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'roster': roster.toJson(),
    'turnTaking': turnTaking.toJson(),
    'transcriptPath': transcriptPath,
    'agentSessions': {
      for (final entry in agentSessions.entries) entry.key: entry.value.toJson(),
    },
    if (lastLocalOrchestrationSessionId.isNotEmpty)
      'lastLocalOrchestrationSessionId': lastLocalOrchestrationSessionId,
  };

  GroupConversationRecord copyWith({
    GroupRoster? roster,
    TurnTakingPolicy? turnTaking,
    String? transcriptPath,
    Map<String, GroupAgentSessionBinding>? agentSessions,
    String? lastLocalOrchestrationSessionId,
  }) {
    return GroupConversationRecord(
      id: id,
      title: title,
      roster: roster ?? this.roster,
      turnTaking: turnTaking ?? this.turnTaking,
      transcriptPath: transcriptPath ?? this.transcriptPath,
      agentSessions: agentSessions ?? this.agentSessions,
      lastLocalOrchestrationSessionId:
          lastLocalOrchestrationSessionId ??
          this.lastLocalOrchestrationSessionId,
    );
  }
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
    final updated = room.copyWith(
      roster: GroupRoster(
        participants: participants,
        mainAgentId: mainAgentId.trim().isEmpty ? null : mainAgentId.trim(),
      ),
    );
    await save(portableData, updated);
    return updated;
  }

  /// Remember the last native conversation returned for [agentId] in this room.
  Future<GroupConversationRecord> upsertAgentSession({
    required Object portableData,
    required String agentId,
    String nativeSessionId = '',
    String sourcePath = '',
    String workingDirectory = '',
    String localOrchestrationSessionId = '',
  }) async {
    final room = await ensureDefaultLicoRoom(portableData);
    final id = agentId.trim();
    final localId = localOrchestrationSessionId.trim();
    final previous = id.isEmpty ? null : room.bindingFor(id);
    final binding = id.isEmpty
        ? null
        : GroupAgentSessionBinding(
            agentId: id,
            nativeSessionId: nativeSessionId.trim().isNotEmpty
                ? nativeSessionId.trim()
                : previous?.nativeSessionId ?? '',
            sourcePath: sourcePath.trim().isNotEmpty
                ? sourcePath.trim()
                : previous?.sourcePath ?? '',
            workingDirectory: workingDirectory.trim().isNotEmpty
                ? workingDirectory.trim()
                : previous?.workingDirectory ?? '',
            updatedAtUnixMs: DateTime.now().toUtc().millisecondsSinceEpoch,
          );
    final shouldWriteBinding =
        binding != null &&
        (binding.hasResumeHandle || binding.workingDirectory.isNotEmpty);
    if (!shouldWriteBinding && localId.isEmpty) {
      return room;
    }
    final sessions = Map<String, GroupAgentSessionBinding>.from(
      room.agentSessions,
    );
    if (shouldWriteBinding) {
      sessions[id] = binding;
    }
    final updated = room.copyWith(
      agentSessions: sessions,
      lastLocalOrchestrationSessionId: localId.isNotEmpty
          ? localId
          : room.lastLocalOrchestrationSessionId,
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
        // Peers are scheduled by LicoUp handoff, not client fan-out.
        return [
          PlannedAgentTurn(agentId: main, role: PlannedTurnRole.dispatcher),
        ];
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
