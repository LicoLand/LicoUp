import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/work_control_models.dart';
import 'package:licoup/src/frontend/shared/ui/apple_buttons.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Explicit force-stop confirmation.
///
/// The dialog renders the exact consequences a native preview read and offers
/// two choices: continue waiting, or force stop. It has no timer, no default
/// action and no dismissal that could signal anything — a dismissal is the
/// same "send nothing" answer as continue-waiting, and only the explicit
/// force-stop button resolves `true`.
///
/// Affected tasks and risk codes come from the preview. When the host reported
/// no unsaved-progress code the dialog still states the standing risk, because
/// terminating a process group always ends whatever its tasks had not saved.
class ForceStopDialog extends StatefulWidget {
  const ForceStopDialog({
    super.key,
    required this.preview,
    required this.chinese,
  });

  final ForceStopPreview preview;
  final bool chinese;

  @override
  State<ForceStopDialog> createState() => _ForceStopDialogState();
}

class _ForceStopDialogState extends State<ForceStopDialog> {
  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final preview = widget.preview;
    final chinese = widget.chinese;
    final textTheme = Theme.of(context).textTheme;
    final risks = <String>[
      forceStopRiskLabel('unsaved-agent-progress', chinese: chinese),
      for (final code in preview.riskCodes)
        if (code != 'unsaved-agent-progress')
          forceStopRiskLabel(code, chinese: chinese),
    ];

    return AlertDialog(
      key: const Key('force-stop-dialog'),
      title: Text(chinese ? '强制停止？' : 'Force stop?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              chinese
                  ? '强制停止会立即终止这个本地 Agent 服务的进程组。'
                  : 'A force stop terminates the process group of this local Agent service immediately.',
              style: textTheme.bodyMedium?.copyWith(color: colors.text),
            ),
            const SizedBox(height: LicoContentSpacing.compact),
            Text(
              chinese
                  ? '将停止的任务（${preview.affectedTaskCount}）'
                  : 'Tasks that stop (${preview.affectedTaskCount})',
              key: const Key('force-stop-affected-headline'),
              style: textTheme.labelMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
            for (final task in preview.affectedTasks)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  task.taskRef.isEmpty
                      ? task.taskKind
                      : '${task.taskKind} · ${task.taskRef}',
                  key: Key('force-stop-affected-${task.taskRef}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(color: colors.text),
                ),
              ),
            if (preview.affectedTaskCount > preview.affectedTasks.length)
              Text(
                chinese
                    ? '还有 ${preview.affectedTaskCount - preview.affectedTasks.length} 个未列出。'
                    : '${preview.affectedTaskCount - preview.affectedTasks.length} more are not listed.',
                key: const Key('force-stop-affected-more'),
                style: textTheme.bodySmall?.copyWith(color: colors.textMuted),
              ),
            const SizedBox(height: LicoContentSpacing.compact),
            Text(
              chinese ? '风险' : 'Risk',
              style: textTheme.labelMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
            for (final risk in risks)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  risk,
                  style: textTheme.bodySmall?.copyWith(color: colors.warning),
                ),
              ),
            if (preview.diagnosticReference.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: LicoContentSpacing.compact),
                child: Text(
                  '${chinese ? '诊断引用' : 'Diagnostic reference'}: ${preview.diagnosticReference}',
                  key: const Key('force-stop-diagnostic-reference'),
                  style: textTheme.bodySmall?.copyWith(color: colors.textMuted),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('force-stop-continue-waiting'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(chinese ? '继续等待' : 'Keep waiting'),
        ),
        TextButton(
          key: const Key('force-stop-confirm'),
          style: AppleControlButtons.glassOutlined(colors),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(chinese ? '强制停止' : 'Force stop'),
        ),
      ],
    );
  }
}

/// Shows [ForceStopDialog] and resolves true only for an explicit force stop.
///
/// A dismissal, a back gesture and "keep waiting" all resolve false and the
/// caller must then send nothing.
Future<bool> showForceStopDialog(
  BuildContext context, {
  required ForceStopPreview preview,
  required bool chinese,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ForceStopDialog(preview: preview, chinese: chinese),
  );
  return confirmed == true;
}
