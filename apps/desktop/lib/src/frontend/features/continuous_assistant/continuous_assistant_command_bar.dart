import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_command_intent.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_keys.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_labels.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_task_view.dart';
import 'package:licoup/src/frontend/shared/ui/apple_buttons.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Accessible correct / pause / cancel controls.
///
/// Presses emit [ContinuousAssistantCommandIntent] only. They do not write
/// Goal lifecycle or control locally.
final class ContinuousAssistantCommandBar extends StatelessWidget {
  const ContinuousAssistantCommandBar({
    super.key,
    required this.goalId,
    required this.lifecycle,
    this.control = ContinuityGoalControl.enabled,
    this.onCommand,
  });

  final String goalId;
  final ContinuityGoalLifecycle lifecycle;
  final ContinuityGoalControl control;
  final ValueChanged<ContinuousAssistantCommandIntent>? onCommand;

  @override
  Widget build(BuildContext context) {
    final labels = ContinuousAssistantLabels.of(context);
    final colors = context.licoColors;
    final style = AppleControlButtons.glassOutlined(colors);
    final absorbing = continuousAssistantLifecycleIsAbsorbing(lifecycle);

    return Wrap(
      spacing: LicoContentSpacing.compact,
      runSpacing: LicoContentSpacing.inline,
      children: [
        _CommandButton(
          key: ContinuousAssistantKeys.correct(goalId),
          label: labels.correct,
          style: style,
          onPressed: onCommand == null
              ? null
              : () => onCommand!(
                  ContinuousAssistantCommandIntent(
                    command: ContinuityCommand.correctAssociation,
                    goalId: goalId,
                  ),
                ),
        ),
        if (!absorbing) ...[
          if (control == ContinuityGoalControl.paused)
            _CommandButton(
              key: ContinuousAssistantKeys.resume(goalId),
              label: labels.resume,
              style: style,
              onPressed: onCommand == null
                  ? null
                  : () => onCommand!(
                      ContinuousAssistantCommandIntent(
                        command: ContinuityCommand.resumeGoal,
                        goalId: goalId,
                      ),
                    ),
            )
          else
            _CommandButton(
              key: ContinuousAssistantKeys.pause(goalId),
              label: labels.pause,
              style: style,
              onPressed: onCommand == null
                  ? null
                  : () => onCommand!(
                      ContinuousAssistantCommandIntent(
                        command: ContinuityCommand.pauseGoal,
                        goalId: goalId,
                      ),
                    ),
            ),
          _CommandButton(
            key: ContinuousAssistantKeys.cancel(goalId),
            label: labels.cancel,
            style: style,
            onPressed: onCommand == null
                ? null
                : () => onCommand!(
                    ContinuousAssistantCommandIntent(
                      command: ContinuityCommand.requestCancel,
                      goalId: goalId,
                    ),
                  ),
          ),
        ],
      ],
    );
  }
}

final class _CommandButton extends StatefulWidget {
  const _CommandButton({
    super.key,
    required this.label,
    required this.style,
    required this.onPressed,
  });

  final String label;
  final ButtonStyle style;
  final VoidCallback? onPressed;

  @override
  State<_CommandButton> createState() => _CommandButtonState();
}

final class _CommandButtonState extends State<_CommandButton> {
  late final FocusNode _focusNode = FocusNode(debugLabel: widget.label);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.onPressed != null,
      label: widget.label,
      child: TextButton(
        focusNode: _focusNode,
        style: widget.style,
        onPressed: widget.onPressed,
        child: Text(widget.label),
      ),
    );
  }
}
