import 'client_controller_scenario_dependencies.dart';
import 'fake_agent_archive_job_fixture.dart';
import 'fake_agent_state_support.dart';

mixin FakeAgentArchiveSupport on AgentService, FakeAgentStateSupport {
  int collectSnapshotsCalls = 0;
  int archiveJobPreviewCalls = 0;
  int archiveJobCreateCalls = 0;
  int archiveJobStatusCalls = 0;
  int archiveJobEventsCalls = 0;
  int archiveJobDrainCalls = 0;
  int snapshotRootGetCalls = 0;
  int snapshotRootSetCalls = 0;
  int snapshotCollectionsListCalls = 0;
  int archiveProfilesListCalls = 0;
  int archiveRunCalls = 0;
  int archiveVerifyCalls = 0;
  int archiveReportCalls = 0;

  String archiveSelectionMode = '';
  String archiveQuery = '';
  String archiveSourceAgentId = '';
  String archivePlanBinding = '';
  String archiveDestinationPath = '';

  String collectedSnapshotTopic = '';
  String collectedSnapshotAgent = '';

  String archiveCollectionPath = '';
  String snapshotRootPath = 'test-data/lico-native-conversation-snapshots';
  String archiveProfileId = '';

  List<Map<String, dynamic>> snapshotCollections = const [];
  List<Map<String, dynamic>> archiveProfiles = const [
    {
      'profileId': 'licomesh',
      'displayName': 'LicoMesh',
      'archiveRoot': 'test-data/licomesh-archive',
    },
  ];

  Completer<void>? archiveJobDrainGate;
  int archiveJobAttempt = 1;
  Map<String, dynamic> archiveJobState = const {};

  FakeArchiveJobContext get _archiveJobContext => (
    archiveCollectionPath: archiveCollectionPath,
    archiveDestinationPath: archiveDestinationPath,
    archivePlanBinding: archivePlanBinding,
    archiveQuery: archiveQuery,
    archiveSelectionMode: archiveSelectionMode,
    archiveSourceAgentId: archiveSourceAgentId,
    scanTargetsResult: scanTargetsResult,
  );

  Future<Map<String, dynamic>?> handleFakeAgentArchiveCli(
    List<String> args,
  ) async {
    if (args.isNotEmpty && args.first == 'snapshots') {
      if (args.length >= 2 && args[1] == 'collect') {
        collectSnapshotsCalls++;
        collectedSnapshotTopic = fakeAgentArgValue(args, '--topic');
        collectedSnapshotAgent = fakeAgentArgValue(args, '--agent');
        snapshotCollections = [
          {
            'topic': collectedSnapshotTopic,
            'topicKey': collectedSnapshotTopic.replaceAll(' ', '-'),
            'state': 'materialized',
            'conversationCount': 1,
          },
        ];
        return {
          'ok': true,
          'status': 'materialized',
          'topic': collectedSnapshotTopic,
          'selectedCount': 1,
        };
      }
      if (args.length >= 3 && args[1] == 'root' && args[2] == 'get') {
        snapshotRootGetCalls++;
        return {
          'ok': true,
          'snapshotRoot': snapshotRootPath,
          'mode': 'default',
        };
      }
      if (args.length >= 3 && args[1] == 'root' && args[2] == 'set') {
        snapshotRootSetCalls++;
        snapshotRootPath = fakeAgentArgValue(args, '--path');
        return {'ok': true, 'status': 'set', 'snapshotRoot': snapshotRootPath};
      }
      if (args.length >= 3 && args[1] == 'collections' && args[2] == 'list') {
        snapshotCollectionsListCalls++;
        return {'ok': true, 'collections': snapshotCollections};
      }
      if (args.length >= 3 && args[1] == 'profiles' && args[2] == 'list') {
        archiveProfilesListCalls++;
        return {'ok': true, 'profiles': archiveProfiles};
      }
      if (args.length >= 4 && args[1] == 'archive' && args[2] == 'jobs') {
        switch (args[3]) {
          case 'preview':
            archiveJobPreviewCalls++;
            archiveSelectionMode = fakeAgentArgValue(args, '--selection-mode');
            archiveQuery = fakeAgentArgValue(args, '--query');
            archiveSourceAgentId = fakeAgentArgValue(args, '--agent');
            archiveDestinationPath = fakeAgentArgValue(args, '--path');
            return {
              'ok': true,
              'mode': 'conversation-archive-plan',
              'plan': {
                'selectionMode': archiveSelectionMode,
                'source': {
                  'kind': 'local-native-history',
                  'agents': [
                    if (archiveSourceAgentId.isNotEmpty) archiveSourceAgentId,
                  ],
                },
                'query': archiveQuery,
                'destination': archiveDestinationPath,
                'count': 2,
                'conflict': false,
                'conflictPolicy': 'merge-local-archive',
                'collectionKey': archiveSelectionMode == 'all'
                    ? 'all-conversations'
                    : archiveQuery.replaceAll(' ', '-').toLowerCase(),
                'binding': 'sha256:fake-archive-plan',
              },
            };
          case 'create':
            archiveJobCreateCalls++;
            archiveSelectionMode = fakeAgentArgValue(args, '--selection-mode');
            archiveQuery = fakeAgentArgValue(args, '--query');
            archiveSourceAgentId = fakeAgentArgValue(args, '--agent');
            archivePlanBinding = fakeAgentArgValue(args, '--plan-binding');
            archiveDestinationPath = fakeAgentArgValue(args, '--path');
            archiveJobState = buildFakeArchiveJob(
              _archiveJobContext,
              status: 'queued',
              attempt: 0,
            );
            return archiveJobState;
          case 'drain':
            archiveJobDrainCalls++;
            if (archiveJobDrainGate != null) {
              await archiveJobDrainGate!.future;
            }
            snapshotCollections = [
              {
                'topic': archiveSelectionMode == 'all'
                    ? 'all-conversations'
                    : archiveQuery,
                'topicKey': archiveSelectionMode == 'all'
                    ? 'all-conversations'
                    : archiveQuery.replaceAll(' ', '-'),
                'state': 'archived',
                'conversationCount': 2,
              },
            ];
            archiveJobState = buildFakeArchiveJob(
              _archiveJobContext,
              status: 'completed',
              attempt: archiveJobAttempt,
            );
            return {
              'ok': true,
              'status': 'drained',
              'processed': 1,
              'completed': 1,
              'failed': 0,
              'deferred': 0,
              'jobs': [
                {'jobId': 'archive-job-1', 'outcome': archiveJobState},
              ],
            };
          case 'status':
            archiveJobStatusCalls++;
            return archiveJobState.isEmpty
                ? buildFakeArchiveJob(
                    _archiveJobContext,
                    status: 'queued',
                    attempt: 0,
                  )
                : archiveJobState;
          case 'events':
            archiveJobEventsCalls++;
            final job = archiveJobState.isEmpty
                ? buildFakeArchiveJob(
                    _archiveJobContext,
                    status: 'queued',
                    attempt: 0,
                  )
                : archiveJobState;
            return {
              'ok': true,
              'jobId': 'archive-job-1',
              'events': job['events'],
            };
        }
      }
      if (args.length >= 3 && args[1] == 'archive' && args[2] == 'run') {
        archiveRunCalls++;
        archiveProfileId = fakeAgentArgValue(args, '--profile');
        return {
          'ok': true,
          'status': 'materialized',
          'mode': 'conversation-archive',
          'profileId': archiveProfileId,
          'indexCount': 2,
          'selectedCount': 2,
          'validation': {'healthStatus': 'ok', 'errorCount': 0},
        };
      }
      if (args.length >= 3 && args[1] == 'archive' && args[2] == 'verify') {
        archiveVerifyCalls++;
        archiveProfileId = fakeAgentArgValue(args, '--profile');
        final collectionPath = fakeAgentArgValue(args, '--collection-path');
        return {
          'ok': true,
          'mode': 'conversation-archive-verify',
          'profileId': archiveProfileId,
          if (collectionPath.isNotEmpty) 'collectionPath': collectionPath,
          'validation': {'healthStatus': 'ok', 'errorCount': 0},
        };
      }
      if (args.length >= 3 && args[1] == 'archive' && args[2] == 'report') {
        archiveReportCalls++;
        archiveProfileId = fakeAgentArgValue(args, '--profile');
        return {
          'ok': true,
          'mode': 'conversation-archive-report',
          'profileId': archiveProfileId,
          'indexCount': 2,
          'validation': {'healthStatus': 'ok', 'errorCount': 0},
        };
      }
    }
    return null;
  }
}
