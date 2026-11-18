import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// Feature-local English/Chinese labels.
///
/// Reuses [LicoStrings] owner getters where they already exist. New
/// Continuous Assistant phrasing stays in this leaf so the shared l10n
/// parent is not edited in parallel.
final class ContinuousAssistantLabels {
  const ContinuousAssistantLabels(this.strings);

  factory ContinuousAssistantLabels.of(BuildContext context) {
    return ContinuousAssistantLabels(LicoStrings.of(context));
  }

  final LicoStrings strings;

  bool get _zh => strings.isChinese;

  String get pause => _zh ? '暂停' : 'Pause';
  String get resume => _zh ? '恢复' : 'Resume';
  String get openCompletedTask => _zh ? '打开原事项' : 'Open original matter';
  String get correct => _zh ? '更正' : 'Correct';
  String get cancel => strings.cancel;
  String get details => strings.details;
  String get waiting => strings.waiting;
  String get expand => _zh ? '展开事项' : 'Expand matter';
  String get collapse => _zh ? '收起事项' : 'Collapse matter';
  String get openChild => _zh ? '打开子对话' : 'Open child conversation';
  String get composer => _zh ? '继续对话' : 'Continue conversation';
  String get source => _zh ? '来源' : 'Source';
  String get executor => _zh ? '执行者' : 'Executor';
  String get participants => _zh ? '参与者' : 'Participants';
  String get nextResponsible => _zh ? '下一责任方' : 'Next responsible party';
  String get waitReason => _zh ? '等待原因' : 'Wait reason';
  String get evidence => _zh ? '证据' : 'Evidence';
  String get completionNotice => _zh ? '目标完成通知' : 'Goal completion notice';
  String get unavailable => _zh ? '连续性不可用' : 'Continuity unavailable';
  String get childTasks => _zh ? '子对话' : 'Child conversations';

  String cardSemantics({
    required String title,
    required String lifecycle,
    required int sequence,
  }) {
    return _zh
        ? '事项卡片 $title，状态 $lifecycle，锚点 $sequence'
        : 'Matter card $title, status $lifecycle, anchor $sequence';
  }

  String childSemantics({
    required String title,
    required String childConversationId,
  }) {
    return _zh
        ? '子对话 $title，$childConversationId'
        : 'Child conversation $title, $childConversationId';
  }

  String noticeSemantics({
    required String notificationId,
    required String toLifecycle,
  }) {
    return _zh
        ? '完成通知 $notificationId，状态 $toLifecycle'
        : 'Completion notice $notificationId, status $toLifecycle';
  }

  String lifecycle(ContinuityGoalLifecycle value) => value.wireName;

  String control(ContinuityGoalControl value) => value.wireName;
}
