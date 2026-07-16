import 'package:flutter_client/src/application/features/agents/archive/conversation_archive_projection.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

/// Owns explicit topic collection only; durable all/exact-keyword backups are
/// owned by [ConversationArchiveJobController].
mixin ConversationSnapshotCollectionController on AgentWorkspaceCoordinator {
  Future<void> collectConversationArchive(String topic) async {
    final agent = selectedConversationAgent;
    final trimmedTopic = topic.trim();
    if (agent == null ||
        trimmedTopic.isEmpty ||
        isCollectingConversationArchive) {
      return;
    }
    isCollectingConversationArchive = true;
    lastError = '';
    agentWorkspaceSetLocalizedStatusMessage(
      '正在归档 ${agent.label} 相关原生对话。',
      'Archiving native conversations related to ${agent.label}.',
    );
    statusCaption = 'Agent archive';
    agentWorkspaceNotifyStateChanged();
    try {
      final result = await conversationGateway.collectSnapshots(
        agentId: agent.target,
        topic: trimmedTopic,
      );
      conversationArchiveResult = boundedArchiveOperationResult(result);
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
      final selectedCount = (result['selectedCount'] as num?)?.toInt() ?? 0;
      agentWorkspaceSetLocalizedStatusMessage(
        selectedCount == 0 ? '已创建空归档集合。' : '已归档 $selectedCount 条原生对话。',
        selectedCount == 0
            ? 'Created an empty archive collection.'
            : 'Archived $selectedCount native conversations.',
      );
      statusCaption = 'Agent archive';
    } catch (_) {
      lastError = 'conversation_archive_operation_failed';
      agentWorkspaceSetLocalizedStatusMessage(
        '${agent.label} 对话归档失败。',
        'Failed to archive ${agent.label} conversations.',
      );
      statusCaption = 'Agent archive';
    } finally {
      isCollectingConversationArchive = false;
      agentWorkspaceNotifyStateChanged();
    }
  }
}
