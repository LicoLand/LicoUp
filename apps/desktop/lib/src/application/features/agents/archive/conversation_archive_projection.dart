import 'package:flutter_client/src/contracts/target_candidate.dart';

Map<String, dynamic> boundedArchiveItem(
  Object? value,
  Set<String> allowedKeys,
) {
  if (value is! Map) return const {};
  final result = <String, dynamic>{};
  for (final key in allowedKeys) {
    final candidate = value[key];
    if (candidate is bool || candidate is num) {
      result[key] = candidate;
    } else if (candidate is String &&
        candidate.length <= 256 &&
        !candidate.contains(RegExp(r'[\r\n]'))) {
      result[key] = candidate;
    }
  }
  return result;
}

List<Map<String, dynamic>> boundedArchiveItems(
  List<Map<String, dynamic>> values,
  Set<String> allowedKeys,
) => List.unmodifiable(
  values.map(
    (value) => Map<String, dynamic>.unmodifiable(
      boundedArchiveItem(value, allowedKeys),
    ),
  ),
);

Map<String, dynamic> boundedArchiveOperationResult(Map<String, dynamic> value) {
  final result = boundedArchiveItem(value, const {
    'ok',
    'status',
    'phase',
    'jobId',
    'mode',
    'entry',
    'selectionMode',
    'query',
    'documentCount',
    'selectedCount',
    'indexCount',
  });
  final validation = boundedArchiveItem(value['validation'], const {
    'healthStatus',
    'status',
    'documentCount',
    'indexCount',
    'missingCount',
    'invalidCount',
  });
  final workflow = boundedArchiveItem(value['workflow'], const {
    'status',
    'attempt',
    'maxAttempts',
  });
  final targetScan = boundedArchiveItem(value['targetScan'], const {
    'clientCount',
    'detectedCount',
    'candidateCount',
  });
  if (validation.isNotEmpty) {
    result['validation'] = Map.unmodifiable(validation);
  }
  if (workflow.isNotEmpty) {
    result['workflow'] = Map.unmodifiable(workflow);
  }
  if (targetScan.isNotEmpty) {
    result['targetScan'] = Map.unmodifiable(targetScan);
  }
  return Map.unmodifiable(result);
}

Map<String, dynamic> boundedArchivePlan(Object? value) {
  final plan = boundedArchiveItem(value, const {
    'selectionMode',
    'query',
    'destination',
    'count',
    'conflict',
    'conflictPolicy',
    'collectionKey',
  });
  if (value is Map && value['source'] is Map) {
    final rawSource = value['source'] as Map;
    final agents = rawSource['agents'] is List
        ? (rawSource['agents'] as List)
              .map((agent) => agent.toString().trim())
              .where((agent) => agent.isNotEmpty && agent.length <= 64)
              .take(16)
              .toList(growable: false)
        : const <String>[];
    plan['source'] = Map<String, dynamic>.unmodifiable({
      'kind': (rawSource['kind'] ?? '').toString(),
      'agents': agents,
    });
  }
  return Map.unmodifiable(plan);
}

List<Map<String, dynamic>> boundedArchiveJobEvents(Map<String, dynamic> job) {
  return (job['events'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(
        (event) => boundedArchiveItem(event, const {
          'type',
          'status',
          'attempt',
          'maxAttempts',
          'createdAt',
          'updatedAt',
        }),
      )
      .toList(growable: false);
}

List<TargetCandidate> targetCandidatesFromArchiveJob(Map<String, dynamic> job) {
  final targetScan = job['targetScan'];
  if (targetScan is! Map) return const [];
  return (targetScan['candidates'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(TargetCandidate.fromJson)
      .toList();
}

Map<String, dynamic> conversationArchiveResultFromJob(
  Map<String, dynamic> job,
) {
  final archiveResult = job['archiveResult'] is Map
      ? Map<String, dynamic>.from(job['archiveResult'] as Map)
      : <String, dynamic>{};
  final validationResult = job['validationResult'] is Map
      ? Map<String, dynamic>.from(job['validationResult'] as Map)
      : const <String, dynamic>{};
  final validation = validationResult['validation'] is Map
      ? Map<String, dynamic>.from(validationResult['validation'] as Map)
      : archiveResult['validation'];
  final status = (job['status'] ?? 'queued').toString();
  final result = <String, dynamic>{
    'ok': status == 'completed',
    'status': status,
    'phase': (job['phase'] ?? status).toString(),
    'jobId': (job['jobId'] ?? '').toString(),
    'mode': 'conversation-archive-job',
    'entry': 'selection-archive-job',
    'targetScan': boundedArchiveItem(
      job['targetScanSummary'] ?? job['targetScan'],
      const {'clientCount', 'detectedCount', 'candidateCount'},
    ),
    'workflow': boundedArchiveItem(job['workflow'], const {
      'status',
      'attempt',
      'maxAttempts',
    }),
    'workflowEvents': boundedArchiveJobEvents(job),
  };
  final request = job['request'];
  final plan = boundedArchivePlan(
    job['plan'] ?? (request is Map ? request['plan'] : null),
  );
  if (plan.isNotEmpty) result['plan'] = plan;
  for (final key in const ['documentCount', 'selectedCount', 'indexCount']) {
    final value = archiveResult[key];
    if (value is num) result[key] = value.toInt();
  }
  final boundedValidation = boundedArchiveItem(validation, const {
    'healthStatus',
    'status',
    'documentCount',
    'indexCount',
    'missingCount',
    'invalidCount',
  });
  if (boundedValidation.isNotEmpty) result['validation'] = boundedValidation;
  return Map.unmodifiable(result);
}
