import 'dart:async';

import 'package:path/path.dart' as p;

import 'package:licoup/src/application/features/agents/archive/conversation_archive_projection.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

const conversationArchiveAllSelection = 'all';
const conversationArchiveExactKeywordSelection = 'exact-keyword';

mixin ConversationArchiveJobController on AgentWorkspaceCoordinator {
  Future<void> archiveSelectedConversationAgent() async {
    final agent = selectedConversationAgent;
    if (agent == null || isCollectingConversationArchive) return;
    final agentId = agent.target.trim();
    final archiveRoot = archiveDestinationDraft.trim();
    if (agentId.isEmpty) return;
    if (archiveRoot.isEmpty) {
      lastError = 'conversation_archive_destination_required';
      agentWorkspaceSetLocalizedStatusMessage(
        '请先在设置中指定对话归档目录。',
        'Choose a conversation archive directory in Settings first.',
      );
      statusCaption = 'Agent archive';
      agentWorkspaceNotifyStateChanged();
      return;
    }
    await archiveAllConversations(
      sourceAgentId: agentId,
      path: conversationArchiveDestinationFor(
        selectionMode: conversationArchiveAllSelection,
        sourceAgentId: agentId,
        root: archiveRoot,
      ),
    );
  }

  String conversationArchiveDestinationFor({
    required String selectionMode,
    String sourceAgentId = '',
    String? root,
  }) {
    final archiveRoot = (root ?? archiveDestinationDraft).trim();
    final agentId = sourceAgentId.trim();
    if (archiveRoot.isEmpty ||
        selectionMode != conversationArchiveAllSelection ||
        agentId.isEmpty) {
      return archiveRoot;
    }
    return p.join(archiveRoot, _conversationArchiveAgentDirectory(agentId));
  }

  Future<void> archiveAllConversations({
    String? path,
    String sourceAgentId = '',
  }) => _archiveConversationSelection(
    selectionMode: conversationArchiveAllSelection,
    query: '',
    path: path,
    sourceAgentId: sourceAgentId,
  );

  Future<void> archiveConversationExactKeyword({
    String? query,
    String? path,
    String sourceAgentId = '',
  }) => _archiveConversationSelection(
    selectionMode: conversationArchiveExactKeywordSelection,
    query: (query ?? archiveQueryDraft).trim(),
    path: path,
    sourceAgentId: sourceAgentId,
  );

  Future<void> openConversationArchiveDirectory() async {
    await agentWorkspaceOpenDirectory(
      archiveDestinationDraft,
      caption: 'Conversation archive',
    );
  }

  Future<void> _archiveConversationSelection({
    required String selectionMode,
    required String query,
    String? path,
    required String sourceAgentId,
  }) async {
    final destination = (path ?? archiveDestinationDraft).trim();
    final exactKeyword =
        selectionMode == conversationArchiveExactKeywordSelection;
    if (destination.isEmpty ||
        (exactKeyword && query.isEmpty) ||
        isCollectingConversationArchive) {
      return;
    }
    isCollectingConversationArchive = true;
    lastError = '';
    conversationArchivePlan = null;
    agentWorkspaceSetLocalizedStatusMessage(
      '正在预览本机对话归档计划。',
      'Previewing the local conversation archive plan.',
    );
    statusCaption = 'Conversation archive';
    agentWorkspaceNotifyStateChanged();
    try {
      final preview = await conversationGateway.previewArchiveJob(
        selectionMode: selectionMode,
        query: query,
        sourceAgentId: sourceAgentId,
        path: destination,
      );
      final rawPlan = preview['plan'];
      if (preview['ok'] != true || rawPlan is! Map) {
        throw const FormatException('conversation archive preview failed');
      }
      final plan = Map<String, dynamic>.from(rawPlan);
      final planBinding = (plan['binding'] ?? '').toString().trim();
      if (planBinding.isEmpty) {
        throw const FormatException(
          'conversation archive plan binding missing',
        );
      }
      conversationArchivePlan = boundedArchivePlan(plan);
      final created = await conversationGateway.createArchiveJob(
        selectionMode: selectionMode,
        query: query,
        sourceAgentId: sourceAgentId,
        path: destination,
        planBinding: planBinding,
      );
      final jobId = (created['jobId'] ?? '').toString();
      selectedConversationArchiveJobId = jobId;
      conversationArchiveWorkflowEvents = boundedArchiveJobEvents(created);
      scannedTargets = targetCandidatesFromArchiveJob(created);
      agentWorkspaceSelectDefaultConversationAgent();
      conversationArchiveResult = conversationArchiveResultFromJob(created);
      conversationArchiveReport = null;
      final scan = created['targetScanSummary'] is Map
          ? Map<String, dynamic>.from(created['targetScanSummary'] as Map)
          : const <String, dynamic>{};
      final clientCount = (scan['clientCount'] as num?)?.toInt() ?? 0;
      final detectedCount = (scan['detectedCount'] as num?)?.toInt() ?? 0;
      final count = (plan['count'] as num?)?.toInt() ?? 0;
      final conflict = plan['conflict'] == true;
      agentWorkspaceSetLocalizedStatusMessage(
        '归档计划已绑定 $count 条本机对话${conflict ? '，目标存在可合并内容' : ''}；扫描 $clientCount 个目标，$detectedCount 个可用，正在运行。',
        'The archive plan bound $count local conversations${conflict ? ' with mergeable destination content' : ''}. Scanned $clientCount targets, found $detectedCount available, and started the job.',
      );
      statusCaption = 'Conversation archive';
      agentWorkspaceNotifyStateChanged();
      unawaited(_drainConversationArchiveJob(jobId));
    } catch (_) {
      lastError = 'conversation_archive_operation_failed';
      agentWorkspaceSetLocalizedStatusMessage(
        '本机对话归档计划或任务创建失败。',
        'Failed to plan or create the local conversation archive job.',
      );
      statusCaption = 'Conversation archive';
      isCollectingConversationArchive = false;
      agentWorkspaceNotifyStateChanged();
    }
  }

  Future<void> _drainConversationArchiveJob(String jobId) async {
    if (jobId.trim().isEmpty) {
      isCollectingConversationArchive = false;
      agentWorkspaceNotifyStateChanged();
      return;
    }
    try {
      await conversationGateway.drainArchiveJobs(jobId: jobId);
      await observeConversationArchiveJob(jobId, refreshCollections: true);
      _finishConversationArchiveJobStatus();
    } catch (_) {
      lastError = 'conversation_archive_operation_failed';
      agentWorkspaceSetLocalizedStatusMessage(
        '本机对话归档任务运行失败。',
        'The local conversation archive job failed to run.',
      );
      statusCaption = 'Conversation archive';
    } finally {
      isCollectingConversationArchive = false;
      agentWorkspaceNotifyStateChanged();
    }
  }

  Future<void> observeConversationArchiveJob(
    String jobId, {
    bool refreshCollections = false,
    bool notify = true,
  }) async {
    final trimmed = jobId.trim();
    if (trimmed.isEmpty) return;
    final job = await conversationGateway.archiveJobStatus(jobId: trimmed);
    final events = await conversationGateway.archiveJobEvents(jobId: trimmed);
    final eventItems =
        ((events['events'] as List?) ?? (job['events'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
    selectedConversationArchiveJobId = trimmed;
    conversationArchiveWorkflowEvents = boundedArchiveJobEvents({
      'events': eventItems,
    });
    conversationArchiveResult = conversationArchiveResultFromJob({
      ...job,
      'events': eventItems,
    });
    conversationArchiveReport = job['validationResult'] is Map
        ? boundedArchiveOperationResult(
            Map<String, dynamic>.from(job['validationResult'] as Map),
          )
        : conversationArchiveReport;
    if (refreshCollections) {
      conversationSnapshotCollections = boundedArchiveItems(
        await conversationGateway.listSnapshotCollections(),
        const {
          'collectionId',
          'id',
          'agentId',
          'status',
          'selectedCount',
          'documentCount',
          'messageCount',
          'createdAt',
          'updatedAt',
        },
      );
    }
    if (notify) agentWorkspaceNotifyStateChanged();
  }

  void _finishConversationArchiveJobStatus() {
    final result = conversationArchiveResult;
    if (result == null) return;
    final documentCount =
        (result['documentCount'] as num?)?.toInt() ??
        (result['selectedCount'] as num?)?.toInt() ??
        0;
    final validation = result['validation'];
    final health = validation is Map
        ? (validation['healthStatus'] ?? 'unknown').toString()
        : '';
    final workflow = result['workflow'] is Map
        ? Map<String, dynamic>.from(result['workflow'] as Map)
        : <String, dynamic>{};
    final status = (workflow['status'] ?? result['status'] ?? '').toString();
    if (status == 'completed') {
      agentWorkspaceSetLocalizedStatusMessage(
        health.isEmpty
            ? '已归档 $documentCount 条原生对话到目录。'
            : '已归档 $documentCount 条原生对话到目录，本机校验 $health。',
        health.isEmpty
            ? 'Archived $documentCount native conversations to the directory.'
            : 'Archived $documentCount native conversations to the directory. Local validation: $health.',
      );
    } else if (status == 'failed') {
      agentWorkspaceSetLocalizedStatusMessage(
        '本机对话归档任务失败。',
        'The local conversation archive job failed.',
      );
    } else if (status == 'retry_scheduled') {
      agentWorkspaceSetLocalizedStatusMessage(
        '本机对话归档任务已安排重试。',
        'The local conversation archive job is scheduled to retry.',
      );
    } else {
      agentWorkspaceSetLocalizedStatusMessage(
        '本机对话归档任务状态：$status。',
        'Local conversation archive job status: $status.',
      );
    }
    statusCaption = 'Conversation archive';
  }

  String _conversationArchiveAgentDirectory(String agentId) {
    final sanitized = agentId
        .trim()
        .replaceAll(RegExp(r'[\\/]+'), '-')
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    return sanitized.isEmpty ? 'agent' : sanitized;
  }
}
