import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';

abstract interface class AgentConversationGateway {
  Future<List<AgentConversationSession>> loadSessions({
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  });

  Stream<AgentConversationSession> streamSessions({
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  });

  Future<AgentDispatchSession> openOrResume({
    required String agentId,
    String sessionId = '',
    AgentDispatchBind bind = const AgentDispatchBind(),
  });

  Future<AgentDispatchTurnResult> send({
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  });

  Stream<AgentDispatchEvent> sendStreaming({
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  });

  Future<AgentDispatchTurnResult> steer({
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  });

  Future<AgentDispatchCancelResult> cancel({
    required String agentId,
    required String sessionId,
    String turnId = '',
  });

  Future<Map<String, dynamic>> previewArchiveJob({
    required String selectionMode,
    required String path,
    String query = '',
    String sourceAgentId = '',
  });
  Future<Map<String, dynamic>> createArchiveJob({
    required String selectionMode,
    required String path,
    required String planBinding,
    String query = '',
    String sourceAgentId = '',
  });
  Future<Map<String, dynamic>> drainArchiveJobs({String jobId = ''});
  Future<Map<String, dynamic>> archiveJobStatus({required String jobId});
  Future<Map<String, dynamic>> archiveJobEvents({required String jobId});
  Future<Map<String, dynamic>> collectSnapshots({
    required String topic,
    String agentId = '',
  });
  Future<List<Map<String, dynamic>>> listSnapshotCollections();
  Future<List<Map<String, dynamic>>> listArchiveProfiles();
  Future<Map<String, dynamic>> runArchiveProfile({
    required String profileId,
    String trigger = 'manual',
  });
  Future<Map<String, dynamic>> verifyArchiveProfile({
    required String profileId,
  });
  Future<Map<String, dynamic>> reportArchiveProfile({
    required String profileId,
  });
  Future<Map<String, dynamic>> getSnapshotRoot();
  Future<Map<String, dynamic>> setSnapshotRoot({required String path});
}

abstract interface class MobileAgentConversationGateway {
  Future<Map<String, dynamic>> send({
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
  });

  Future<Map<String, dynamic>> listSessions({
    required String agentId,
    int limit = 20,
    int offset = 0,
  });

  Future<Map<String, dynamic>> describeSession({
    required String agentId,
    required String sessionId,
  });
}
