import 'package:licoup/src/application/features/agents/archive/conversation_archive_projection.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

mixin ConversationArchiveSettingsController on AgentWorkspaceCoordinator {
  Future<void> refreshConversationSnapshotRoot() async {
    try {
      final result = await conversationGateway.getSnapshotRoot();
      snapshotRootDraft = (result['snapshotRoot'] ?? '').toString();
      snapshotRootState = boundedArchiveItem(result, const {'ok', 'status'});
      if (archiveDestinationDraft.trim().isEmpty) {
        archiveDestinationDraft = snapshotRootDraft;
      }
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
    } catch (_) {
      lastError = 'conversation_archive_operation_failed';
    } finally {
      agentWorkspaceNotifyStateChanged();
    }
  }

  Future<void> setConversationSnapshotRoot(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty || isSavingSnapshotRoot) return;
    isSavingSnapshotRoot = true;
    lastError = '';
    agentWorkspaceSetLocalizedStatusMessage(
      '正在更新对话归档目录。',
      'Updating the conversation archive directory.',
    );
    statusCaption = 'Settings';
    agentWorkspaceNotifyStateChanged();
    try {
      final result = await conversationGateway.setSnapshotRoot(path: trimmed);
      snapshotRootDraft = (result['snapshotRoot'] ?? trimmed).toString();
      snapshotRootState = boundedArchiveItem(result, const {'ok', 'status'});
      archiveDestinationDraft = snapshotRootDraft;
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
      agentWorkspaceSetLocalizedStatusMessage(
        result['ok'] == true ? '对话归档目录已更新。' : '对话归档目录未更新。',
        result['ok'] == true
            ? 'Conversation archive directory updated.'
            : 'Conversation archive directory was not updated.',
      );
      statusCaption = 'Settings';
    } catch (_) {
      lastError = 'conversation_archive_operation_failed';
      agentWorkspaceSetLocalizedStatusMessage(
        '对话归档目录更新失败。',
        'Failed to update the conversation archive directory.',
      );
      statusCaption = 'Settings';
    } finally {
      isSavingSnapshotRoot = false;
      agentWorkspaceNotifyStateChanged();
    }
  }
}
