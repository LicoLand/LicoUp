import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/work_control_models.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Localized copy for one visible stop stage.
String workStopStageLabel(WorkStopStage stage, {required bool chinese}) =>
    switch (stage) {
      WorkStopStage.idle => '',
      WorkStopStage.stopping => chinese ? '正在停止…' : 'Stopping…',
      WorkStopStage.stopped => chinese ? '已停止' : 'Stopped',
      WorkStopStage.unconfirmed => chinese ? '停止结果未确认' : 'Stop unconfirmed',
    };

/// The visible stop state of one piece of admitted work.
///
/// It renders the projected stage and — only for an unconfirmed stop — the
/// explicit route to a force stop. A confirmed stop and an in-progress stop
/// never offer it: the surface never escalates on its own.
///
/// [diagnosticReference] is a short local reference (an opaque correlation
/// id). No raw error, path or payload is rendered.
class WorkStopIndicator extends StatelessWidget {
  const WorkStopIndicator({
    super.key,
    required this.stage,
    this.diagnosticReference = '',
    this.chinese = false,
    this.onForceStop,
  });

  final WorkStopStage stage;
  final String diagnosticReference;
  final bool chinese;
  final VoidCallback? onForceStop;

  @override
  Widget build(BuildContext context) {
    final label = workStopStageLabel(stage, chinese: chinese);
    if (label.isEmpty) return const SizedBox.shrink();
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      key: const Key('work-stop-indicator'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            key: const Key('work-stop-stage'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(
              color: stage == WorkStopStage.unconfirmed
                  ? colors.warning
                  : colors.textSecondary,
            ),
          ),
        ),
        if (diagnosticReference.isNotEmpty) ...[
          const SizedBox(width: LicoContentSpacing.inline),
          Flexible(
            child: Text(
              diagnosticReference,
              key: const Key('work-stop-diagnostic-reference'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: colors.textMuted),
            ),
          ),
        ],
        if (stage == WorkStopStage.unconfirmed && onForceStop != null) ...[
          const SizedBox(width: LicoContentSpacing.inline),
          TextButton(
            key: const Key('work-stop-force'),
            onPressed: onForceStop,
            child: Text(chinese ? '强制停止…' : 'Force stop…'),
          ),
        ],
      ],
    );
  }
}
