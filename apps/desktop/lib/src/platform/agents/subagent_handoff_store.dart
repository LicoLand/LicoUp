import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/storage/portable_data_root.dart';

class SubagentHandoffRecord {
  const SubagentHandoffRecord({
    required this.dispatchId,
    required this.operation,
    required this.managerAgentId,
    required this.agentId,
    required this.state,
    this.sessionMode = 'new',
    this.mainConversationPath,
    this.conversationPath,
    this.errorCode,
    required this.updatedAtUnixMs,
  });

  final String dispatchId;
  final String operation;
  final String managerAgentId;
  final String agentId;
  final String state;
  final String sessionMode;
  final String? mainConversationPath;
  final String? conversationPath;
  final String? errorCode;
  final int updatedAtUnixMs;

  bool get isTerminal => state == 'completed' || state == 'failed';

  factory SubagentHandoffRecord.fromJson(Map<String, dynamic> json) {
    return SubagentHandoffRecord(
      dispatchId: (json['dispatchId'] ?? '').toString(),
      operation: (json['operation'] ?? '').toString(),
      managerAgentId: (json['managerAgentId'] ?? '').toString(),
      agentId: (json['agentId'] ?? '').toString(),
      state: (json['state'] ?? '').toString(),
      sessionMode: (json['sessionMode'] ?? 'new').toString(),
      mainConversationPath: json['mainConversationPath']?.toString(),
      conversationPath: json['conversationPath']?.toString(),
      errorCode: json['errorCode']?.toString(),
      updatedAtUnixMs: (json['updatedAtUnixMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class SubagentHandoffStore {
  static Future<Directory> root(PortableDataRoot portableData) async {
    final client = await portableData.clientDirectory();
    return Directory('${client.path}/subagent-handoffs');
  }

  static Future<List<SubagentHandoffRecord>> list(
    PortableDataRoot portableData,
  ) async {
    final dir = await root(portableData);
    if (!await dir.exists()) return const [];
    final records = <SubagentHandoffRecord>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = await entity.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          records.add(SubagentHandoffRecord.fromJson(decoded));
        } else if (decoded is Map) {
          records.add(
            SubagentHandoffRecord.fromJson(
              decoded.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      } catch (_) {
        // Skip malformed handoff files.
      }
    }
    records.sort((a, b) => b.updatedAtUnixMs.compareTo(a.updatedAtUnixMs));
    return records;
  }
}
