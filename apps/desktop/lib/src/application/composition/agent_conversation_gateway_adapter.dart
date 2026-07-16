import 'package:flutter_client/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';

final class AgentConversationGatewayAdapter
    implements AgentConversationGateway {
  const AgentConversationGatewayAdapter({
    required this.service,
    required this.runner,
  });

  final AgentConversationService service;
  final AgentCommandRunner runner;

  @override
  Future<List<AgentConversationSession>> loadSessions({
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) => service.loadSessions(
    agentService: runner,
    agentId: agentId,
    sessionId: sessionId,
    limit: limit,
    offset: offset,
  );
  @override
  Stream<AgentConversationSession> streamSessions({
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
  }) => service.streamSessions(
    agentService: runner,
    agentId: agentId,
    sessionId: sessionId,
    limit: limit,
    offset: offset,
  );
  @override
  Future<AgentDispatchSession> openOrResume({
    required String agentId,
    String sessionId = '',
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => service.openOrResume(
    runner: runner,
    agentId: agentId,
    sessionId: sessionId,
    bind: bind,
  );
  @override
  Future<AgentDispatchTurnResult> send({
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  }) => service.send(
    runner: runner,
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    bind: bind,
    conversationReadiness: conversationReadiness,
    requireReady: requireReady,
  );
  @override
  Stream<AgentDispatchEvent> sendStreaming({
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  }) => service.sendStreaming(
    runner: runner,
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    bind: bind,
    conversationReadiness: conversationReadiness,
    requireReady: requireReady,
  );
  @override
  Future<AgentDispatchTurnResult> steer({
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => service.steer(
    runner: runner,
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    bind: bind,
  );
  @override
  Future<AgentDispatchCancelResult> cancel({
    required String agentId,
    required String sessionId,
    String turnId = '',
  }) => service.cancel(
    runner: runner,
    agentId: agentId,
    sessionId: sessionId,
    turnId: turnId,
  );
  @override
  Future<Map<String, dynamic>> previewArchiveJob({
    required String selectionMode,
    required String path,
    String query = '',
    String sourceAgentId = '',
  }) => service.previewArchiveJob(
    agentService: runner,
    selectionMode: selectionMode,
    path: path,
    query: query,
    sourceAgentId: sourceAgentId,
  );
  @override
  Future<Map<String, dynamic>> createArchiveJob({
    required String selectionMode,
    required String path,
    required String planBinding,
    String query = '',
    String sourceAgentId = '',
  }) => service.createArchiveJob(
    agentService: runner,
    selectionMode: selectionMode,
    path: path,
    planBinding: planBinding,
    query: query,
    sourceAgentId: sourceAgentId,
  );
  @override
  Future<Map<String, dynamic>> drainArchiveJobs({String jobId = ''}) =>
      service.drainArchiveJobs(agentService: runner, jobId: jobId);
  @override
  Future<Map<String, dynamic>> archiveJobStatus({required String jobId}) =>
      service.archiveJobStatus(agentService: runner, jobId: jobId);
  @override
  Future<Map<String, dynamic>> archiveJobEvents({required String jobId}) =>
      service.archiveJobEvents(agentService: runner, jobId: jobId);
  @override
  Future<Map<String, dynamic>> collectSnapshots({
    required String topic,
    String agentId = '',
  }) => service.collectSnapshots(
    agentService: runner,
    topic: topic,
    agentId: agentId,
  );
  @override
  Future<List<Map<String, dynamic>>> listSnapshotCollections() =>
      service.listSnapshotCollections(agentService: runner);
  @override
  Future<List<Map<String, dynamic>>> listArchiveProfiles() =>
      service.listArchiveProfiles(agentService: runner);
  @override
  Future<Map<String, dynamic>> runArchiveProfile({
    required String profileId,
    String trigger = 'manual',
  }) => service.runArchiveProfile(
    agentService: runner,
    profileId: profileId,
    trigger: trigger,
  );
  @override
  Future<Map<String, dynamic>> verifyArchiveProfile({
    required String profileId,
  }) =>
      service.verifyArchiveProfile(agentService: runner, profileId: profileId);
  @override
  Future<Map<String, dynamic>> reportArchiveProfile({
    required String profileId,
  }) =>
      service.reportArchiveProfile(agentService: runner, profileId: profileId);
  @override
  Future<Map<String, dynamic>> getSnapshotRoot() =>
      service.getSnapshotRoot(agentService: runner);
  @override
  Future<Map<String, dynamic>> setSnapshotRoot({required String path}) =>
      service.setSnapshotRoot(agentService: runner, path: path);
}

final class MobileAgentConversationGatewayAdapter
    implements MobileAgentConversationGateway {
  const MobileAgentConversationGatewayAdapter({
    required this.service,
    required this.agentService,
  });

  final MobileRelayService service;
  final AgentService agentService;

  @override
  Future<Map<String, dynamic>> send({
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
  }) => service.sendSecureAgentMessage(
    agentService: agentService,
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    model: model,
    reasoningEffort: reasoningEffort,
  );
  @override
  Future<Map<String, dynamic>> listSessions({
    required String agentId,
    int limit = 20,
    int offset = 0,
  }) => service.listSecureAgentSessions(
    agentService: agentService,
    agentId: agentId,
    limit: limit,
    offset: offset,
  );
  @override
  Future<Map<String, dynamic>> describeSession({
    required String agentId,
    required String sessionId,
  }) => service.describeSecureAgentSession(
    agentService: agentService,
    agentId: agentId,
    sessionId: sessionId,
  );
}
