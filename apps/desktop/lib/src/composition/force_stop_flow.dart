import 'package:flutter/widgets.dart';

import 'package:licoup/src/composition/work_control_presentation.dart';
import 'package:licoup/src/contracts/presentation/work_control_models.dart';
import 'package:licoup/src/frontend/features/runtime_control/force_stop_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';

/// Runs the explicit force-stop flow for one unconfirmed stop.
///
/// The flow is deliberately three visible steps and nothing else:
///
/// 1. read the native preview (which sends no signal),
/// 2. show the affected tasks and the risk, and wait for an explicit choice,
/// 3. send exactly one confirm only when the user chose to force stop.
///
/// A preview that cannot be confirmed reports its own reason code and sends
/// nothing. Declining clears the preview and sends nothing. There is no timer,
/// no default and no retry.
Future<void> openForceStopConfirmation(
  BuildContext context,
  WorkControlPresentation workControl,
) async {
  final chinese = LicoStrings.of(context).isChinese;
  final preview = await workControl.previewForceStop();
  if (!context.mounted) return;
  if (!preview.confirmable) {
    showLicoToast(
      context,
      message: chinese
          ? '无法确认要强制停止的进程组。'
          : 'The process group to force stop could not be confirmed.',
      kind: LicoToastKind.error,
    );
    return;
  }
  final confirmed = await showForceStopDialog(
    context,
    preview: preview,
    chinese: chinese,
  );
  if (!confirmed) {
    workControl.declineForceStop();
    return;
  }
  final confirmation = await workControl.confirmForceStop();
  if (!context.mounted) return;
  final reference = confirmation.diagnosticReference;
  showLicoToast(
    context,
    message: switch (confirmation.status) {
      ForceStopConfirmationStatus.observedExit =>
        chinese
            ? '已确认进程组退出。${_reference(chinese, reference)}'
            : 'The process group exit was observed. ${_reference(chinese, reference)}',
      ForceStopConfirmationStatus.unconfirmed =>
        chinese
            ? '未观察到退出，结果未确认。${_reference(chinese, reference)}'
            : 'No exit was observed; the outcome is unconfirmed. ${_reference(chinese, reference)}',
      ForceStopConfirmationStatus.declined =>
        chinese ? '已取消强制停止。' : 'The force stop was declined.',
      ForceStopConfirmationStatus.invalid =>
        chinese
            ? '强制停止请求无效。${_reference(chinese, reference)}'
            : 'The force-stop request was invalid. ${_reference(chinese, reference)}',
      ForceStopConfirmationStatus.unavailable =>
        chinese
            ? '无法执行强制停止。${_reference(chinese, reference)}'
            : 'The force stop could not be executed. ${_reference(chinese, reference)}',
    },
    kind: confirmation.stopped ? LicoToastKind.info : LicoToastKind.error,
  );
}

String _reference(bool chinese, String reference) =>
    reference.isEmpty ? '' : '(${chinese ? '诊断引用' : 'ref'} $reference)';
