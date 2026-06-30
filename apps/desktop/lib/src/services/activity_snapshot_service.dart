import 'agent_service.dart';

class ActivitySnapshotState {
  const ActivitySnapshotState({
    required this.activityPath,
    required this.events,
    required this.snapshots,
    required this.conversationCollections,
  });

  final String activityPath;
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> snapshots;
  final List<Map<String, dynamic>> conversationCollections;

  factory ActivitySnapshotState.empty() {
    return const ActivitySnapshotState(
      activityPath: '',
      events: [],
      snapshots: [],
      conversationCollections: [],
    );
  }
}

class ActivitySnapshotService {
  const ActivitySnapshotService();

  Future<ActivitySnapshotState> load(AgentService agentService) async {
    final activity = await agentService.runCli([
      'activity',
      'list',
      '--limit',
      '80',
    ]);
    final snapshots = await agentService.runCli(['snapshots', 'list']);
    final collections = await agentService.runCli([
      'snapshots',
      'collections',
      'list',
    ]);
    return ActivitySnapshotState(
      activityPath: (activity['path'] ?? '').toString(),
      events: _listFromOutput(activity, 'events'),
      snapshots: _listFromOutput(snapshots, 'snapshots'),
      conversationCollections: _listFromOutput(collections, 'collections'),
    );
  }

  List<Map<String, dynamic>> _listFromOutput(
    Map<String, dynamic> output,
    String key,
  ) {
    if (output['ok'] == true && output[key] is List) {
      return (output[key] as List).whereType<Map<String, dynamic>>().toList();
    }
    return const [];
  }
}
