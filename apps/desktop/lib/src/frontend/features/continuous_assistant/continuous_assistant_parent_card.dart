import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_command_bar.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_command_intent.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_keys.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_labels.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_task_view.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Parent timeline card anchored at [ContinuityParentCardAnchor.sequence].
///
/// Progress and completion update this same card. Expand state is local UI
/// only. Closing the card does not emit cancel.
final class ContinuousAssistantParentCard extends StatefulWidget {
  const ContinuousAssistantParentCard({
    super.key,
    required this.task,
    this.onOpenChild,
    this.onCommand,
    this.initiallyExpanded = false,
    this.focused = false,
  });

  final ContinuousAssistantTaskView task;
  final ValueChanged<ContinuousAssistantTaskView>? onOpenChild;
  final ValueChanged<ContinuousAssistantCommandIntent>? onCommand;
  final bool initiallyExpanded;
  final bool focused;

  @override
  State<ContinuousAssistantParentCard> createState() =>
      _ContinuousAssistantParentCardState();
}

final class _ContinuousAssistantParentCardState
    extends State<ContinuousAssistantParentCard> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final goalId = task.relation.goalId;
    final labels = ContinuousAssistantLabels.of(context);
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final title = continuousAssistantTaskTitle(task);
    final lifecycle = task.progress.lifecycle.wireName;
    final sequence = task.relation.cardAnchor.sequence;
    final wait = task.progress.nextAttention is ContinuityNextAttentionWait
        ? task.progress.nextAttention! as ContinuityNextAttentionWait
        : null;

    return Semantics(
      key: ContinuousAssistantKeys.card(goalId),
      container: true,
      label: labels.cardSemantics(
        title: title,
        lifecycle: lifecycle,
        sequence: sequence,
      ),
      child: LicoSurface(
        selected: widget.focused,
        padding: const EdgeInsets.all(LicoContentSpacing.compact),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    label: labels.openChild,
                    child: InkWell(
                      key: ContinuousAssistantKeys.openCard(goalId),
                      onTap: widget.onOpenChild == null
                          ? null
                          : () => widget.onOpenChild!(task),
                      child: Text(
                        title,
                        key: ContinuousAssistantKeys.title(goalId),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium,
                      ),
                    ),
                  ),
                ),
                Semantics(
                  button: true,
                  expanded: _expanded,
                  label: _expanded ? labels.collapse : labels.expand,
                  child: LicoIconButton(
                    key: ContinuousAssistantKeys.expand(goalId),
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                    ),
                    tooltip: _expanded ? labels.collapse : labels.expand,
                    size: LicoIconButtonSize.small,
                    shape: LicoIconButtonShape.concentric,
                    radius: LicoRadius.nested(
                      LicoRadius.card,
                      LicoContentSpacing.compact,
                    ),
                    onPressed: _toggleExpanded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: LicoContentSpacing.inline),
            Wrap(
              spacing: LicoContentSpacing.compact,
              runSpacing: LicoContentSpacing.inline,
              children: [
                Text(
                  lifecycle,
                  key: ContinuousAssistantKeys.lifecycle(goalId),
                  style: LicoTypography.eyebrow(color: colors.textSecondary),
                ),
                Text(
                  task.progress.control.wireName,
                  key: ContinuousAssistantKeys.control(goalId),
                  style: LicoTypography.eyebrow(color: colors.textMuted),
                ),
                Text(
                  '$sequence',
                  key: ContinuousAssistantKeys.sequence(goalId),
                  style: LicoTypography.mono(color: colors.textMuted),
                ),
              ],
            ),
            if (!_expanded)
              Padding(
                padding: const EdgeInsets.only(top: LicoContentSpacing.inline),
                child: Text(
                  continuousAssistantCollapsedProgress(task.progress),
                  key: ContinuousAssistantKeys.collapsed(goalId),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            _ExpandingFacts(
              duration: context.motion(LicoMotion.medium),
              child: _expanded
                  ? _ExpandedFacts(
                      task: task,
                      labels: labels,
                      colors: colors,
                      wait: wait,
                      onCommand: widget.onCommand,
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// Animated only when motion is allowed. A zero-duration [AnimatedSize]
/// re-dirties itself during layout; reduced motion therefore swaps statically.
final class _ExpandingFacts extends StatelessWidget {
  const _ExpandingFacts({required this.duration, required this.child});

  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (duration == Duration.zero) {
      return child;
    }
    return AnimatedSize(
      duration: duration,
      curve: LicoMotion.standard,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

final class _ExpandedFacts extends StatelessWidget {
  const _ExpandedFacts({
    required this.task,
    required this.labels,
    required this.colors,
    required this.wait,
    required this.onCommand,
  });

  final ContinuousAssistantTaskView task;
  final ContinuousAssistantLabels labels;
  final LicoThemeColors colors;
  final ContinuityNextAttentionWait? wait;
  final ValueChanged<ContinuousAssistantCommandIntent>? onCommand;

  @override
  Widget build(BuildContext context) {
    final goalId = task.relation.goalId;
    final textTheme = Theme.of(context).textTheme;
    final contract = task.contract;
    final responsible = wait?.responsibleParty ?? contract?.responsibleRoleRef;
    final sources = <ContinuitySourceRef>[
      ...?contract?.sourceIntentRefs,
      ...task.progress.criterionEvidenceRefs.map((item) => item.source),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: LicoContentSpacing.compact),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            labels.source,
            style: LicoTypography.eyebrow(color: colors.textMuted),
          ),
          for (final source in sources)
            Text(
              source.opaqueId,
              key: ContinuousAssistantKeys.source(goalId, source.opaqueId),
              style: LicoTypography.mono(color: colors.text),
            ),
          const SizedBox(height: LicoContentSpacing.compact),
          Text(
            labels.executor,
            style: LicoTypography.eyebrow(color: colors.textMuted),
          ),
          for (final work in task.childWorkContexts)
            Text(
              work.membershipId,
              key: ContinuousAssistantKeys.executor(goalId, work.membershipId),
              style: LicoTypography.mono(color: colors.text),
            ),
          Text(
            labels.participants,
            style: LicoTypography.eyebrow(color: colors.textMuted),
          ),
          for (final work in task.childWorkContexts)
            Text(
              work.membershipId,
              key: ContinuousAssistantKeys.participant(
                goalId,
                work.membershipId,
              ),
              style: textTheme.bodySmall,
            ),
          if (responsible != null) ...[
            Text(
              labels.nextResponsible,
              style: LicoTypography.eyebrow(color: colors.textMuted),
            ),
            Text(
              responsible,
              key: ContinuousAssistantKeys.responsible(goalId),
              style: LicoTypography.mono(color: colors.text),
            ),
          ],
          if (wait != null) ...[
            Text(
              labels.waitReason,
              style: LicoTypography.eyebrow(color: colors.textMuted),
            ),
            Text(
              '${wait!.triggerRef} ${wait!.reviewPolicy}',
              key: ContinuousAssistantKeys.waitReason(goalId),
              style: textTheme.bodySmall,
            ),
          ],
          if (task.progress.criterionEvidenceRefs.isNotEmpty) ...[
            Text(
              labels.evidence,
              style: LicoTypography.eyebrow(color: colors.textMuted),
            ),
            for (final evidence in task.progress.criterionEvidenceRefs)
              Text(
                '${evidence.issuer} ${evidence.source.opaqueId} ${evidence.result.wireName}',
                key: ContinuousAssistantKeys.evidence(
                  goalId,
                  evidence.source.opaqueId,
                ),
                style: textTheme.bodySmall,
              ),
          ],
          const SizedBox(height: LicoContentSpacing.compact),
          ContinuousAssistantCommandBar(
            goalId: goalId,
            lifecycle: task.progress.lifecycle,
            control: task.progress.control,
            onCommand: onCommand,
          ),
        ],
      ),
    );
  }
}
