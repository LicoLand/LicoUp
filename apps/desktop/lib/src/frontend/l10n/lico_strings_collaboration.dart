import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings_base.dart';

/// Collaboration flowchart copy: run header, cards, plan revisions, gates and
/// command errors.
extension LicoStringsCollaboration on LicoStrings {
  String get collaborationTitle => isChinese ? '协作流程' : 'Collaboration';
  String get collaborationLoading =>
      isChinese ? '正在读取协作运行…' : 'Loading the collaboration run…';
  String get collaborationUnavailable =>
      isChinese ? '协作运行暂不可用' : 'Collaboration runs are unavailable';
  String get collaborationNone =>
      isChinese ? '此会话暂无协作运行' : 'No collaboration run in this conversation';
  String get collaborationNoGroupSelected =>
      isChinese ? '选择一个群聊查看协作流程' : 'Select a group to see its collaboration';
  String get collaborationNoGroupSelectedMessage => isChinese
      ? '协作流程跟随右侧选中的群聊，展示计划、进度和待你决定的事项。'
      : 'The flowchart follows the group selected in the chat sidebar: its '
            'plan, progress and the decisions waiting for you.';
  String get collaborationPendingDecisions =>
      isChinese ? '待你决定' : 'Waiting for you';

  String collaborationRunStatus(CollaborationRunStatus status) =>
      switch (status) {
        CollaborationRunStatus.running => isChinese ? '进行中' : 'Running',
        CollaborationRunStatus.waiting => isChinese ? '等待中' : 'Waiting',
        CollaborationRunStatus.completed => isChinese ? '已完成' : 'Completed',
        CollaborationRunStatus.failed => isChinese ? '失败' : 'Failed',
        CollaborationRunStatus.blocked => isChinese ? '已阻塞' : 'Blocked',
        CollaborationRunStatus.cancelled => isChinese ? '已取消' : 'Cancelled',
      };
  String get collaborationAwaitingYou => isChinese ? '待你决定' : 'Your call';
  String collaborationRunChip(String status, int done, int total) =>
      '$status · $done/$total';

  String collaborationCaptionCompleted(int head) =>
      isChinese ? '运行完成 · 计划 v$head' : 'Run complete · plan v$head';
  String collaborationCaptionProposal(int number) => isChinese
      ? 'Lead 提议更新计划至 v$number，等待你审批'
      : 'Lead proposes plan v$number and waits for your review';
  String collaborationCaptionGate(String title) =>
      isChinese ? '等待你对「$title」做出决定' : 'Waiting for your decision on “$title”';
  String collaborationCaptionHistorical(int number) => isChinese
      ? '正在查看 v$number · 历史版本只显示计划结构'
      : 'Viewing v$number · history shows the plan structure only';
  String collaborationCaptionActive(String status, String label) =>
      '$status · $label';
  String collaborationProgress(int done, int total) =>
      isChinese ? '$done/$total 项完成' : '$done/$total done';

  String collaborationNodeStatus(CollaborationNodeStatus status) =>
      switch (status) {
        CollaborationNodeStatus.pending => isChinese ? '待开始' : 'Not started',
        CollaborationNodeStatus.running => isChinese ? '进行中' : 'Running',
        CollaborationNodeStatus.waitingUser => isChinese ? '待你决定' : 'Your call',
        CollaborationNodeStatus.waitingAssistant =>
          isChinese ? '等待 Lead 决定' : 'Waiting for Lead',
        CollaborationNodeStatus.succeeded => isChinese ? '已完成' : 'Done',
        CollaborationNodeStatus.failed => isChinese ? '失败' : 'Failed',
        CollaborationNodeStatus.retrying => isChinese ? '重试中' : 'Retrying',
        CollaborationNodeStatus.cancelled => isChinese ? '已取消' : 'Cancelled',
        CollaborationNodeStatus.heldForPlan =>
          isChinese ? '待计划审批' : 'Held for plan approval',
      };
  String collaborationRetrying(int attempt) =>
      isChinese ? '重试中 · 第 $attempt 次' : 'Retrying · attempt $attempt';
  String collaborationAttempt(int attempt, int max) =>
      isChinese ? '第 $attempt/$max 次' : 'Attempt $attempt/$max';

  String get collaborationViewProgress => isChinese ? '查看进展' : 'Details';
  String collaborationArtifactCount(int count) => isChinese
      ? '$count 个产物'
      : count == 1
      ? '1 artifact'
      : '$count artifacts';
  String collaborationRepeatedFailure(int count) =>
      isChinese ? '同一问题失败 $count 次' : 'Failed $count times on the same issue';
  String collaborationFailedNote(int attempt, int max) =>
      isChinese ? '执行失败 · 第 $attempt/$max 次' : 'Failed · attempt $attempt/$max';
  String collaborationFallbackReceipt(String from, String to, String reason) =>
      isChinese
      ? '已切换 $from → $to · $reason'
      : 'Switched $from → $to · $reason';
  String collaborationFailureClass(String failureClass) =>
      switch (failureClass) {
        'retry_exhausted' => isChinese ? '重试上限' : 'retry limit',
        'timeout' => isChinese ? '超时' : 'timed out',
        'unavailable' => isChinese ? '不可用' : 'unavailable',
        'quota_exhausted' => isChinese ? '额度用尽' : 'quota exhausted',
        _ => isChinese ? '运行异常' : 'runtime failure',
      };
  String collaborationAwaitingMerge({required bool withArtifacts}) =>
      switch ((withArtifacts, isChinese)) {
        (true, true) => '已提交产物，等待汇合',
        (false, true) => '已完成，等待汇合',
        (true, false) => 'Artifacts submitted · waiting to merge',
        (false, false) => 'Done · waiting to merge',
      };
  String get collaborationAssistantApproved =>
      isChinese ? 'Lead 已代批' : 'Approved by Lead';
  String get collaborationHeldForPlan =>
      isChinese ? '待计划审批' : 'Held for plan approval';
  String get collaborationStackHead => isChinese ? 'Lead 编排' : 'Lead sequence';
  String collaborationStepRole(String role, String agent) => '$role · $agent';

  String get collaborationDispatch => isChinese ? '派发' : 'Dispatch';
  String get collaborationMerge => isChinese ? '汇合' : 'Merge';
  String get collaborationChoice => isChinese ? '分支' : 'Branch';
  String get collaborationPass => isChinese ? '继续' : 'Pass';
  String get collaborationDone => isChinese ? '完成' : 'Done';

  String get collaborationAddedTag => isChinese ? '+ 新增' : '+ Added';
  String get collaborationAdjustedTag => isChinese ? '已调整' : 'Adjusted';
  String collaborationReassignedFromTo(String from, String to) =>
      isChinese ? '改派 $from → $to' : 'Reassigned $from → $to';
  String get collaborationProposalTag => isChinese ? '提案' : 'Proposed';
  String collaborationProposalReassignTo(String to) =>
      isChinese ? '提案改派 → $to' : 'Proposed: reassign to $to';
  String get collaborationProposalAdjustTag =>
      isChinese ? '提案调整' : 'Proposed change';
  String get collaborationRemovedTag => isChinese ? '− 移出计划' : '− Removed';

  String collaborationPhaseTitle(int index, String group, String summary) =>
      '${index.toString().padLeft(2, '0')} $group · $summary';
  String collaborationPhaseSteps(int count) => isChinese
      ? '$count 个步骤'
      : count == 1
      ? '1 step'
      : '$count steps';
  String collaborationPhaseAgents(int count) => isChinese
      ? '$count 个执行 Agent'
      : count == 1
      ? '1 agent'
      : '$count agents';

  String get collaborationShowDiff => isChinese ? '显示差异' : 'Show changes';
  String get collaborationFollow => isChinese ? '跟随最新' : 'Follow latest';
  String get collaborationZoomIn => isChinese ? '放大' : 'Zoom in';
  String get collaborationZoomOut => isChinese ? '缩小' : 'Zoom out';
  String get collaborationFit => isChinese ? '适应' : 'Fit';
  String get collaborationMinimap => isChinese ? '流程缩略图' : 'Flowchart overview';
  String get collaborationSettings =>
      isChinese ? '协作设置' : 'Collaboration settings';
  String collaborationRevisionChip(int number, String digest) =>
      'v$number · $digest';
  String get collaborationParticipants => isChinese ? '参与的智能体' : 'Participants';

  String collaborationProposalBanner(int number, String reason) {
    final head = isChinese
        ? 'Lead 提议更新计划 → v$number'
        : 'Lead proposes v$number';
    return reason.isEmpty ? head : '$head · $reason';
  }

  String collaborationAppliedBanner(
    int from,
    int to,
    String approval,
    String reason,
  ) {
    final head = isChinese
        ? '计划已更新 v$from → v$to · $approval'
        : 'Plan updated v$from → v$to · $approval';
    return reason.isEmpty ? head : '$head · $reason';
  }

  String collaborationRevertedBanner(int number, String reason) {
    final head = isChinese
        ? '已撤销计划变更 · v$number'
        : 'Plan change reverted · v$number';
    return reason.isEmpty ? head : '$head · $reason';
  }

  String get collaborationViewChanges => isChinese ? '查看变更' : 'View changes';
  String get collaborationReplay => isChinese ? '回放' : 'Replay';
  String get collaborationRevert => isChinese ? '撤销此变更' : 'Revert this change';
  String get collaborationRestore =>
      isChinese ? '恢复此版本' : 'Restore this version';
  String get collaborationDismiss => isChinese ? '关闭' : 'Dismiss';
  String get collaborationBackToHead => isChinese ? '回到最新' : 'Back to latest';
  String get collaborationApprove => isChinese ? '同意' : 'Approve';
  String get collaborationReject => isChinese ? '拒绝' : 'Reject';
  String get collaborationAskRevise =>
      isChinese ? '让 Lead 修改' : 'Ask Lead to revise';
  String get collaborationReviseHint =>
      isChinese ? '告诉 Lead 怎么改…' : 'Tell Lead what to change…';
  String get collaborationSend => isChinese ? '发送' : 'Send';
  String get collaborationCancel => isChinese ? '取消' : 'Cancel';

  String get collaborationPlanHistory => isChinese ? '计划历史' : 'Plan history';
  String get collaborationCompare =>
      isChinese ? '与上一版对比' : 'Compare with previous';
  String collaborationRevisionAuthor(CollaborationRevisionAuthor author) =>
      switch (author) {
        CollaborationRevisionAuthor.assistant => 'Lead',
        CollaborationRevisionAuthor.user => isChinese ? '你' : 'You',
      };
  String collaborationRevisionApproval(
    CollaborationRevisionApproval approval,
  ) => switch (approval) {
    CollaborationRevisionApproval.autoApplied =>
      isChinese ? '自动同意' : 'Auto-approved',
    CollaborationRevisionApproval.approved =>
      isChinese ? '你已同意' : 'You approved',
    CollaborationRevisionApproval.pending =>
      isChinese ? '待你审批' : 'Pending review',
    CollaborationRevisionApproval.rejected => isChinese ? '已拒绝' : 'Rejected',
  };
  String collaborationRevisionStats(int added, int removed, int changed) =>
      isChinese
      ? '+$added 节点 · −$removed · ~$changed'
      : '+$added nodes · −$removed · ~$changed';
  String collaborationRevertOf(int number) =>
      isChinese ? '撤销 v$number' : 'Reverts v$number';

  String get collaborationEscalatedTitle =>
      isChinese ? 'Lead 无法判断 · 等待你的决定' : 'Lead cannot decide · your call';
  String get collaborationGateWaiting =>
      isChinese ? '需要你的决定' : 'Needs your decision';
  String collaborationAssistantNote(String note) =>
      isChinese ? 'Lead：$note' : 'Lead: $note';
  String collaborationAssistantApprovedReason(String reason) =>
      isChinese ? 'Lead 已代批 · $reason' : 'Approved by Lead · $reason';

  String get collaborationPlanChangePolicy =>
      isChinese ? '计划变更' : 'Plan changes';
  String get collaborationPlanChangeAuto => isChinese ? '自动同意' : 'Auto-approve';
  String get collaborationPlanChangeAsk => isChinese ? '需要我审批' : 'Ask me first';
  String get collaborationGateReviewPolicy => isChinese ? '审批' : 'Gate review';
  String get collaborationGateReviewAssistant =>
      isChinese ? 'Lead 自动审阅（无把握时问我）' : 'Lead reviews (escalates when unsure)';
  String get collaborationGateReviewUser =>
      isChinese ? '全部问我' : 'Always ask me';

  String collaborationConflictNotice(int head) => isChinese
      ? '计划已更新到 v$head，请确认后重试'
      : 'The plan moved to v$head. Review it and try again.';

  /// Friendly text for a stable machine code; unknown codes keep the code so
  /// the failure stays identifiable.
  String collaborationErrorMessage(String code) => switch (code) {
    collaborationRunUnavailable => collaborationUnavailable,
    collaborationRunInvalidPayload =>
      isChinese ? '协作数据无法读取' : 'The collaboration data could not be read',
    'collaboration_revision_unknown' =>
      isChinese ? '找不到该计划版本' : 'That plan revision is not available',
    collaborationCommandFailed =>
      isChinese ? '操作未完成，请重试' : 'The action did not complete. Try again.',
    _ => isChinese ? '操作未完成（$code）' : 'The action did not complete ($code)',
  };
}
