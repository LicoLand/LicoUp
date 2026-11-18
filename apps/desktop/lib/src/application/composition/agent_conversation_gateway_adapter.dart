import 'package:licoup/src/contracts/conversation_execution.dart';
import 'package:licoup/src/contracts/conversation_execution_port.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';

final class AgentConversationGatewayAdapter
    implements
        AgentConversationGateway,
        PersistentAgentConversationGateway,
        ConversationExecutionSource {
  const AgentConversationGatewayAdapter({
    required this.service,
    required this.runner,
  });

  final AgentConversationService service;
  final AgentCommandRunner runner;

  @override
  Stream<ConversationExecutionEvent> watchExecution(
    ConversationExecutionReference reference, {
    int afterCursor = 0,
  }) => service.watchExecution(reference, afterCursor: afterCursor);

  @override
  Future<List<Map<String, dynamic>>> activeTurns({
    required String agentId,
    String sessionId = '',
    String conversationId = '',
    Duration waitForChange = Duration.zero,
  }) => service.activeTurns(
    agentId: agentId,
    sessionId: sessionId,
    conversationId: conversationId,
    waitForChange: waitForChange,
  );

  @override
  Future<void> ensureRuntime({String conversationId = ''}) async {
    await activeTurns(agentId: '', conversationId: conversationId);
  }

  @override
  Stream<AgentDispatchEvent> attachActiveTurn({
    required String turnHandle,
    required String conversationId,
    int afterCursor = 0,
  }) async* {
    try {
      await for (final event in service.attachActiveTurn(
        turnHandle: turnHandle,
        conversationId: conversationId,
        afterCursor: afterCursor,
      )) {
        yield event;
      }
    } on NativeConversationException catch (error) {
      throw AgentDispatchStreamException(error.code);
    }
  }

  @override
  Future<AgentDispatchTurnResult> steerActiveTurn({
    required String turnHandle,
    required String conversationId,
    required String text,
  }) => service.steerActiveTurn(
    turnHandle: turnHandle,
    conversationId: conversationId,
    text: text,
  );

  @override
  Future<AgentDispatchCancelResult> cancelActiveTurn({
    required String turnHandle,
    required String conversationId,
  }) => service.cancelActiveTurn(
    turnHandle: turnHandle,
    conversationId: conversationId,
  );

  @override
  Future<List<AgentConversationSession>> loadSessions({
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    String messageBefore = '',
    int? messageLimit,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => messageLimit == null
      ? service.loadSessions(
          agentService: runner,
          agentId: agentId,
          sessionId: sessionId,
          limit: limit,
          offset: offset,
          bind: bind,
        )
      : service.loadSessionMessagePage(
          agentService: runner,
          agentId: agentId,
          sessionId: sessionId,
          messageBefore: messageBefore,
          messageLimit: messageLimit,
          bind: bind,
        );
  @override
  Stream<AgentConversationSession> streamSessions({
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    String messageBefore = '',
    int? messageLimit,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => messageLimit == null
      ? service.streamSessions(
          agentService: runner,
          agentId: agentId,
          sessionId: sessionId,
          limit: limit,
          offset: offset,
          bind: bind,
        )
      : service.streamSessionMessagePage(
          agentService: runner,
          agentId: agentId,
          sessionId: sessionId,
          messageBefore: messageBefore,
          messageLimit: messageLimit,
          bind: bind,
        );
  @override
  Future<AgentDispatchSession> openOrResume({
    required String agentId,
    String sessionId = '',
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) =>
      service.openOrResume(agentId: agentId, sessionId: sessionId, bind: bind);
  @override
  Future<AgentDispatchTurnResult> send({
    required String agentId,
    required String text,
    required String sessionId,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => service.send(
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    attachments: attachments,
    bind: bind,
  );
  @override
  Stream<AgentDispatchEvent> sendStreaming({
    required String agentId,
    required String text,
    required String sessionId,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async* {
    try {
      await for (final event in service.sendStreaming(
        agentId: agentId,
        text: text,
        sessionId: sessionId,
        attachments: attachments,
        bind: bind,
      )) {
        yield event;
      }
    } on NativeConversationException catch (error) {
      throw AgentDispatchStreamException(error.code);
    }
  }

  @override
  Future<AgentDispatchTurnResult> steer({
    required String agentId,
    required String text,
    required String sessionId,
    required String turnId,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => service.steer(
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    turnId: turnId,
    bind: bind,
  );
  @override
  Future<String> resolveNativeApproval({
    required String agentId,
    required String sessionId,
    required String turnId,
    required String adapterCallbackTokenRef,
    required bool allow,
  }) => service.resolveNativeApproval(
    agentId: agentId,
    sessionId: sessionId,
    turnId: turnId,
    adapterCallbackTokenRef: adapterCallbackTokenRef,
    allow: allow,
  );
  @override
  Future<AgentDispatchCancelResult> cancel({
    required String agentId,
    required String sessionId,
    String turnId = '',
  }) => service.cancel(agentId: agentId, sessionId: sessionId, turnId: turnId);
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
