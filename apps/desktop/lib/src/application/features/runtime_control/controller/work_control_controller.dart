import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/work_control_gateway.dart';
import 'package:licoup/src/contracts/presentation/work_control_models.dart';

/// Localized status copy for one work-control action.
final class WorkControlStatusUpdate {
  const WorkControlStatusUpdate({
    required this.chinese,
    required this.english,
    this.errorCode = '',
    this.diagnosticReference = '',
  });

  final String chinese;
  final String english;
  final String errorCode;

  /// A short local reference for later analysis. Never a raw error or payload.
  final String diagnosticReference;
}

typedef WorkControlStatusSink = void Function(WorkControlStatusUpdate update);

/// Manual stop and explicit force-stop for admitted work.
///
/// The controller holds no business state: it forwards one stop request,
/// projects the bounded owner answer, and re-projects the visible stage from
/// the owning projection's own observation of whether the work is still in
/// flight. It never decides that work stopped, and it never upgrades an
/// unobserved termination into a completion.
///
/// Force stop is two explicit steps. [previewForceStop] reads the durable
/// consequences and sends no signal; [confirmForceStop] sends a signal only
/// when the caller passes `confirmed: true` with the exact token the preview
/// returned. There is no timer, no default and no auto-confirmation here.
final class WorkControlController extends ApplicationStateOwner {
  WorkControlController({required WorkControlGateway gateway})
    : _gateway = gateway;

  final WorkControlGateway _gateway;

  WorkStopRequest? _pendingRequest;
  WorkStopResult? _lastResult;
  ForceStopPreview? _preview;
  ForceStopConfirmation? _lastConfirmation;
  bool _busy = false;
  int _stopRequestCount = 0;

  /// The last stop request this controller forwarded, if any.
  WorkStopRequest? get pendingRequest => _pendingRequest;

  /// The last bounded answer the host returned for [pendingRequest].
  WorkStopResult? get lastStopResult => _lastResult;

  /// The preview currently shown by the force-stop dialog, if any.
  ForceStopPreview? get preview => _preview;

  /// The last observed force-stop outcome, if any.
  ForceStopConfirmation? get lastConfirmation => _lastConfirmation;

  bool get busy => _busy;

  /// How many stop requests this controller actually forwarded. Used by tests
  /// and diagnostics to prove a declined force stop sends nothing.
  int get stopRequestCount => _stopRequestCount;

  /// The visible stage for [observedActive] work.
  WorkStopStage stageFor({required bool observedActive}) {
    if (_busy && _lastResult == null) return WorkStopStage.stopping;
    return projectWorkStopStage(
      result: _lastResult,
      observedActive: observedActive,
    );
  }

  /// Records the bounded outcome of a stop this client performed through its
  /// existing conversation cancel control.
  ///
  /// That control answers with a status and a failure code rather than a
  /// correlation id, so the projection carries no diagnostic reference: an
  /// unreachable or refused cancel stays [WorkStopStage.unconfirmed] and never
  /// becomes a fabricated completion.
  void recordStopOutcome({required bool ok, String failureCode = ''}) {
    _lastResult = ok
        ? const WorkStopResult(
            ok: true,
            status: 'stop-requested',
            disposition: WorkStopDisposition.acknowledged,
          )
        : WorkStopResult(
            ok: false,
            status: 'unconfirmed',
            disposition: WorkStopDisposition.unavailable,
            failureCode: failureCode.trim().isEmpty
                ? 'work_stop_request_failed'
                : failureCode.trim(),
          );
    publishChange();
  }

  /// The local reference for the last stop answer, or empty.
  String get stopDiagnosticReference => _lastResult?.diagnosticReference ?? '';

  /// The local reference for the last force-stop answer, or empty.
  String get forceStopDiagnosticReference =>
      _lastConfirmation?.diagnosticReference ??
      _preview?.diagnosticReference ??
      '';

  /// Forwards one manual stop to the native owner.
  ///
  /// An ambiguous request (more than one durable identity) or an empty one is
  /// refused locally: the host refuses those too, and guessing an owner is
  /// exactly what the native resolver forbids.
  Future<WorkStopResult> stopWork(
    WorkStopRequest request, {
    WorkControlStatusSink? onStatus,
  }) async {
    if (_busy) return _lastResult ?? const WorkStopResult.unavailable();
    if (!request.isResolvable) {
      const refused = WorkStopResult(
        ok: false,
        status: 'invalid',
        disposition: WorkStopDisposition.invalid,
        failureCode: 'work_stop_target_ambiguous',
      );
      _lastResult = refused;
      _pendingRequest = request;
      onStatus?.call(
        const WorkControlStatusUpdate(
          chinese: '停止请求无法定位到唯一任务。',
          english: 'The stop request does not name exactly one task.',
          errorCode: 'work_stop_target_ambiguous',
        ),
      );
      publishChange();
      return refused;
    }
    _busy = true;
    _pendingRequest = request;
    publishChange();
    WorkStopResult result;
    try {
      result = await _gateway.stopWork(request);
    } catch (_) {
      result = const WorkStopResult.unavailable('work_stop_transport_failed');
    }
    _stopRequestCount += 1;
    _lastResult = result;
    _busy = false;
    onStatus?.call(
      WorkControlStatusUpdate(
        chinese: result.requested ? '已请求停止。' : '停止请求未被接受。',
        english: result.requested
            ? 'Stop requested.'
            : 'The stop request was not accepted.',
        errorCode: result.failureCode,
        diagnosticReference: result.diagnosticReference,
      ),
    );
    publishChange();
    return result;
  }

  /// Reads the durable consequences of one force stop. Sends no signal.
  Future<ForceStopPreview> previewForceStop({
    String scopeId = '',
    WorkControlStatusSink? onStatus,
  }) async {
    ForceStopPreview preview;
    try {
      preview = await _gateway.previewForceStop(scopeId: scopeId);
    } catch (_) {
      preview = const ForceStopPreview.unavailable(
        'force_stop_preview_transport_failed',
      );
    }
    _preview = preview;
    if (preview.status != ForceStopPreviewStatus.preview) {
      onStatus?.call(
        WorkControlStatusUpdate(
          chinese: '无法读取需要强制停止的任务。',
          english: 'The tasks a force stop would affect could not be read.',
          errorCode: preview.failureCode.isEmpty
              ? 'force_stop_preview_unavailable'
              : preview.failureCode,
          diagnosticReference: preview.diagnosticReference,
        ),
      );
    }
    publishChange();
    return preview;
  }

  /// Declines the shown force stop. Sends nothing and clears the preview.
  void declineForceStop() {
    _preview = null;
    publishChange();
  }

  /// Confirms the exact previewed force stop.
  ///
  /// The token and scope are taken from the preview the dialog showed, so a
  /// target that changed since the preview is refused by the host instead of
  /// being signalled. Without a confirmable preview this sends nothing.
  Future<ForceStopConfirmation> confirmForceStop({
    WorkControlStatusSink? onStatus,
  }) async {
    final preview = _preview;
    if (preview == null || !preview.confirmable) {
      const refused = ForceStopConfirmation(
        status: ForceStopConfirmationStatus.invalid,
        failureCode: 'force_stop_preview_required',
      );
      onStatus?.call(
        const WorkControlStatusUpdate(
          chinese: '请先查看受影响的再确认强制停止。',
          english: 'Preview the affected tasks before confirming a force stop.',
          errorCode: 'force_stop_preview_required',
        ),
      );
      return refused;
    }
    ForceStopConfirmation confirmation;
    try {
      confirmation = await _gateway.confirmForceStop(
        scopeId: preview.scopeId,
        confirmationToken: preview.confirmationToken,
        confirmed: true,
      );
    } catch (_) {
      confirmation = const ForceStopConfirmation.unavailable(
        'force_stop_confirm_transport_failed',
      );
    }
    _preview = null;
    _lastConfirmation = confirmation;
    onStatus?.call(
      WorkControlStatusUpdate(
        chinese: switch (confirmation.status) {
          ForceStopConfirmationStatus.observedExit => '已确认进程组退出。',
          ForceStopConfirmationStatus.unconfirmed => '未观察到退出，结果未确认。',
          ForceStopConfirmationStatus.declined => '已取消强制停止。',
          ForceStopConfirmationStatus.invalid => '强制停止请求无效。',
          ForceStopConfirmationStatus.unavailable => '无法执行强制停止。',
        },
        english: switch (confirmation.status) {
          ForceStopConfirmationStatus.observedExit =>
            'The process group exit was observed.',
          ForceStopConfirmationStatus.unconfirmed =>
            'No exit was observed; the outcome is unconfirmed.',
          ForceStopConfirmationStatus.declined =>
            'The force stop was declined.',
          ForceStopConfirmationStatus.invalid =>
            'The force-stop request was invalid.',
          ForceStopConfirmationStatus.unavailable =>
            'The force stop could not be executed.',
        },
        errorCode: confirmation.failureCode,
        diagnosticReference: confirmation.diagnosticReference,
      ),
    );
    publishChange();
    return confirmation;
  }

  /// Clears the projected stop answer, for example after the work settled and
  /// the surface no longer shows it.
  void clearStopResult() {
    _lastResult = null;
    _pendingRequest = null;
    publishChange();
  }
}
