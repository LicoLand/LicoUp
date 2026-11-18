import 'client_controller_scenario_dependencies.dart';

typedef FakeArchiveJobContext = ({
  String archiveCollectionPath,
  String archiveDestinationPath,
  String archivePlanBinding,
  String archiveQuery,
  String archiveSelectionMode,
  String archiveSourceAgentId,
  List<TargetCandidate> scanTargetsResult,
});

Map<String, dynamic> buildFakeArchiveJob(
  FakeArchiveJobContext context, {
  required String status,
  required int attempt,
}) {
  final events = <Map<String, dynamic>>[
    {
      'sequence': 1,
      'jobId': 'archive-job-1',
      'type': 'archive.scan.completed',
      'phase': 'queued',
      'status': 'queued',
      'attempt': 0,
    },
    if (attempt > 1)
      {
        'sequence': 2,
        'jobId': 'archive-job-1',
        'type': 'archive.retry.scheduled',
        'phase': 'retry_scheduled',
        'status': 'retry_scheduled',
        'attempt': 1,
      },
    if (status == 'completed')
      {
        'sequence': 3,
        'jobId': 'archive-job-1',
        'type': 'archive.completed',
        'phase': 'completed',
        'status': 'completed',
        'attempt': attempt,
      },
  ];
  return {
    'ok': true,
    'jobId': 'archive-job-1',
    'request': {
      'selectionMode': context.archiveSelectionMode,
      'query': context.archiveQuery,
      'agent': context.archiveSourceAgentId,
      'path': context.archiveDestinationPath,
      'planBinding': context.archivePlanBinding,
    },
    'plan': {
      'selectionMode': context.archiveSelectionMode,
      'source': {
        'kind': 'local-native-history',
        'agents': [
          if (context.archiveSourceAgentId.isNotEmpty)
            context.archiveSourceAgentId,
        ],
      },
      'query': context.archiveQuery,
      'destination': context.archiveDestinationPath,
      'count': 2,
      'conflict': false,
      'conflictPolicy': 'merge-local-archive',
    },
    'status': status,
    'phase': status,
    'attempt': attempt,
    'maxAttempts': 2,
    'targetScan': {
      'ok': true,
      'source': 'target-adapters',
      'candidates': context.scanTargetsResult
          .map((target) => target.toJson())
          .toList(),
    },
    'targetScanSummary': {
      'source': 'target-adapters',
      'clientCount': context.scanTargetsResult.length,
      'detectedCount': context.scanTargetsResult
          .where((target) => target.status != 'not-detected')
          .length,
      'clients': context.scanTargetsResult
          .map((target) => target.toJson())
          .toList(),
    },
    'archiveResult': status == 'completed'
        ? {
            'status': 'archived',
            'archiveRoot': context.archiveDestinationPath,
            'documentCount': 2,
            'selectedCount': 2,
            'selectionMode': context.archiveSelectionMode,
            'query': context.archiveQuery,
            'collectionPath': context.archiveCollectionPath.isEmpty
                ? '${context.archiveDestinationPath}/collection.json'
                : context.archiveCollectionPath,
          }
        : {},
    'validationResult': status == 'completed'
        ? {
            'ok': true,
            'validation': {'healthStatus': 'ok', 'errorCount': 0},
          }
        : {},
    'workflow': {
      'status': status,
      'currentPhase': status,
      'attempt': attempt,
      'maxAttempts': 2,
    },
    'events': events,
    'lastError': '',
  };
}
