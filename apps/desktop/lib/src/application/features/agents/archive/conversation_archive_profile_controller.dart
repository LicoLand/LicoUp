import 'package:flutter_client/src/application/features/agents/archive/conversation_archive_projection.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

mixin ConversationArchiveProfileController on AgentWorkspaceCoordinator {
  Future<void> refreshConversationArchiveProfiles() async {
    try {
      conversationArchiveProfiles = boundedArchiveItems(
        await conversationGateway.listArchiveProfiles(),
        const {'profileId', 'label', 'name', 'status', 'mode'},
      );
      if (selectedArchiveProfileId.isEmpty &&
          conversationArchiveProfiles.isNotEmpty) {
        selectedArchiveProfileId =
            (conversationArchiveProfiles.first['profileId'] ?? '').toString();
      }
      if (selectedArchiveProfileId.isNotEmpty &&
          !conversationArchiveProfiles.any(
            (profile) =>
                (profile['profileId'] ?? '').toString() ==
                selectedArchiveProfileId,
          )) {
        selectedArchiveProfileId = conversationArchiveProfiles.isEmpty
            ? ''
            : (conversationArchiveProfiles.first['profileId'] ?? '').toString();
      }
    } catch (_) {
      lastError = 'conversation_archive_operation_failed';
    } finally {
      agentWorkspaceNotifyStateChanged();
    }
  }

  void selectConversationArchiveProfile(String profileId) {
    selectedArchiveProfileId = profileId.trim();
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> runSelectedConversationArchiveProfile() =>
      _runProfileOperation('run');

  Future<void> verifySelectedConversationArchiveProfile() =>
      _runProfileOperation('verify');

  Future<void> reportSelectedConversationArchiveProfile() =>
      _runProfileOperation('report');

  Future<void> _runProfileOperation(String operation) async {
    final profileId = selectedArchiveProfileId.trim();
    if (profileId.isEmpty || isCollectingConversationArchive) return;
    isCollectingConversationArchive = true;
    lastError = '';
    final verb = switch (operation) {
      'verify' => (
        '正在验证项目对话归档。',
        'Validating the project conversation archive.',
      ),
      'report' => (
        '正在读取项目对话归档报告。',
        'Loading the project conversation archive report.',
      ),
      _ => ('正在运行项目对话归档。', 'Running the project conversation archive.'),
    };
    agentWorkspaceSetLocalizedStatusMessage(verb.$1, verb.$2);
    statusCaption = 'Project archive';
    agentWorkspaceNotifyStateChanged();
    try {
      final result = switch (operation) {
        'verify' => await conversationGateway.verifyArchiveProfile(
          profileId: profileId,
        ),
        'report' => await conversationGateway.reportArchiveProfile(
          profileId: profileId,
        ),
        _ => await conversationGateway.runArchiveProfile(
          profileId: profileId,
          trigger: 'manual',
        ),
      };
      final projection = boundedArchiveOperationResult(result);
      conversationArchiveResult = projection;
      conversationArchiveReport = projection;
      if (operation == 'run') {
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
      final validation = result['validation'];
      final health = validation is Map
          ? (validation['healthStatus'] ?? 'unknown').toString()
          : 'unknown';
      final indexCount = (result['indexCount'] as num?)?.toInt() ?? 0;
      final message = switch (operation) {
        'verify' => (
          '项目归档验证完成：$health。',
          'Project archive validation completed: $health.',
        ),
        'report' => ('项目归档报告已读取。', 'Project archive report loaded.'),
        _ => (
          '项目归档完成：$indexCount 条，健康状态 $health。',
          'Project archive completed with $indexCount entries. Health status: $health.',
        ),
      };
      agentWorkspaceSetLocalizedStatusMessage(message.$1, message.$2);
      statusCaption = 'Project archive';
    } catch (_) {
      lastError = 'conversation_archive_operation_failed';
      agentWorkspaceSetLocalizedStatusMessage(
        '项目对话归档操作失败。',
        'The project conversation archive operation failed.',
      );
      statusCaption = 'Project archive';
    } finally {
      isCollectingConversationArchive = false;
      agentWorkspaceNotifyStateChanged();
    }
  }
}
