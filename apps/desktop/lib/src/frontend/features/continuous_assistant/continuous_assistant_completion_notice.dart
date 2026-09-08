import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_keys.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_labels.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_task_view.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_surface.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Renders a supplied [ContinuityGoalCompletionTransition].
///
/// Does not publish, dedupe, or consume notifications. Rebuilds have no
/// side effects. M2 wires the existing notification center once for a
/// persist-consumed transition.
final class ContinuousAssistantCompletionNotice extends StatelessWidget {
  const ContinuousAssistantCompletionNotice({
    super.key,
    required this.transition,
    this.task,
    this.onOpenChild,
  });

  final ContinuityGoalCompletionTransition transition;
  final ContinuousAssistantTaskView? task;
  final ValueChanged<ContinuousAssistantTaskView>? onOpenChild;

  @override
  Widget build(BuildContext context) {
    final labels = ContinuousAssistantLabels.of(context);
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final task = this.task;

    return Semantics(
      label: labels.noticeSemantics(
        notificationId: transition.notificationId,
        toLifecycle: transition.toLifecycle.wireName,
      ),
      button: task != null && onOpenChild != null,
      child: LicoSurface(
        tone: LicoSurfaceTone.accent,
        radius: LicoRadius.chip,
        padding: const EdgeInsets.all(LicoContentSpacing.compact),
        child: InkWell(
          key: ContinuousAssistantKeys.notice(transition.notificationId),
          onTap: task == null || onOpenChild == null
              ? null
              : () => onOpenChild!(task),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(labels.completionNotice, style: textTheme.labelLarge),
              Text(
                transition.notificationId,
                style: textTheme.bodySmall?.copyWith(color: colors.textMuted),
              ),
              Text(
                transition.toLifecycle.wireName,
                style: textTheme.bodyMedium,
              ),
              Text(
                transition.authorityKind.wireName,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
