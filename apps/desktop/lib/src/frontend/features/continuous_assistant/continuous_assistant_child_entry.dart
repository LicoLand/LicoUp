import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_keys.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_labels.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_task_view.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Standalone child-list leaf. M2 binds the existing sidebar to this item.
///
/// Click identity is [ContinuousAssistantTaskView.relation], the same object
/// the parent card uses.
final class ContinuousAssistantChildEntry extends StatelessWidget {
  const ContinuousAssistantChildEntry({
    super.key,
    required this.task,
    this.onOpenChild,
    this.highlighted = false,
  });

  final ContinuousAssistantTaskView task;
  final ValueChanged<ContinuousAssistantTaskView>? onOpenChild;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final labels = ContinuousAssistantLabels.of(context);
    final colors = context.licoColors;
    final title = continuousAssistantTaskTitle(task);
    final childId = task.relation.childConversationId;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      button: true,
      label: labels.childSemantics(title: title, childConversationId: childId),
      child: LicoSurface(
        selected: highlighted,
        padding: EdgeInsets.zero,
        radius: LicoRadius.chip,
        elevation: LicoElevation.flat,
        child: InkWell(
          key: ContinuousAssistantKeys.child(childId),
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          onTap: onOpenChild == null ? null : () => onOpenChild!(task),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LicoContentSpacing.compact,
              vertical: LicoContentSpacing.inline,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
                Text(
                  childId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LicoTypography.mono(color: colors.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
