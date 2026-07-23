import 'dart:convert';

import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';

export 'package:flutter_client/src/contracts/agent_usage_models.dart';

class AgentUsageService {
  const AgentUsageService();

  Future<AgentUsageReport> scan({
    required AgentCommandRunner agentService,
    String agentId = '',
    bool forceRefresh = false,
    int historyDays = 90,
  }) async {
    final args = ['agent-usage', 'scan'];
    if (agentId.trim().isNotEmpty) {
      args.addAll(['--agent', agentId.trim()]);
    }
    if (forceRefresh) {
      args.add('--force-refresh');
    }
    final normalizedHistoryDays = historyDays.clamp(1, 90).toInt();
    args.addAll(['--history-days', normalizedHistoryDays.toString()]);
    args.addAll([
      '--timezone-offset-minutes',
      DateTime.now().timeZoneOffset.inMinutes.toString(),
    ]);
    args.addAll([
      '--timezone-transitions-json',
      jsonEncode(_localTimezoneTransitions(normalizedHistoryDays)),
    ]);
    final output = await agentService.runCli(args);
    return AgentUsageReport.fromJson(output);
  }

  Future<List<AgentUsageReport>> reports({
    required AgentCommandRunner agentService,
    String agentId = '',
    int limit = 10,
  }) async {
    final args = ['agent-usage', 'report', '--limit', limit.toString()];
    if (agentId.trim().isNotEmpty) {
      args.addAll(['--agent', agentId.trim()]);
    }
    final output = await agentService.runCli(args);
    if (output['schemaVersion'] != AgentUsageReport.currentSchemaVersion ||
        output['mode'] != AgentUsageReport.currentMode ||
        output['tokenSourceMode'] != AgentUsageReport.currentTokenSourceMode) {
      throw const FormatException('Unsupported agent usage reports envelope.');
    }
    final reports = output['reports'];
    if (reports is! List) {
      throw const FormatException('Invalid agent usage reports payload.');
    }
    return reports
        .map((report) {
          if (report is! Map<String, dynamic>) {
            throw const FormatException('Invalid agent usage report entry.');
          }
          return AgentUsageReport.fromJson(report);
        })
        .toList(growable: false);
  }
}

List<Map<String, int>> _localTimezoneTransitions(int historyDays) {
  final now = DateTime.now().toUtc();
  final start = now.subtract(Duration(days: historyDays + 7));
  final end = now.add(const Duration(days: 2));
  var cursor = start;
  var currentOffset = cursor.toLocal().timeZoneOffset.inMinutes;
  final transitions = <Map<String, int>>[
    {'atEpochSeconds': 0, 'offsetMinutes': currentOffset},
  ];
  while (cursor.isBefore(end)) {
    final candidate = cursor.add(const Duration(hours: 6));
    final next = candidate.isAfter(end) ? end : candidate;
    final nextOffset = next.toLocal().timeZoneOffset.inMinutes;
    if (nextOffset != currentOffset) {
      var low = cursor.millisecondsSinceEpoch ~/ 1000;
      var high = next.millisecondsSinceEpoch ~/ 1000;
      while (high - low > 1) {
        final middle = low + ((high - low) ~/ 2);
        final offset = DateTime.fromMillisecondsSinceEpoch(
          middle * 1000,
          isUtc: true,
        ).toLocal().timeZoneOffset.inMinutes;
        if (offset == currentOffset) {
          low = middle;
        } else {
          high = middle;
        }
      }
      currentOffset = DateTime.fromMillisecondsSinceEpoch(
        high * 1000,
        isUtc: true,
      ).toLocal().timeZoneOffset.inMinutes;
      transitions.add({'atEpochSeconds': high, 'offsetMinutes': currentOffset});
    }
    cursor = next;
  }
  return transitions;
}
