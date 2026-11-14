import 'package:licoup/src/contracts/presentation/work_control_models.dart';

/// The native manual-stop and force-stop control lane this client requires.
///
/// Declared contract — the owner of the client/native bridge implements this
/// over the existing structured control lane:
///
/// * [stopWork] → `agent.conversation.stop` with [WorkStopRequest.toJson].
/// * [previewForceStop] → `agent.conversation.force.preview` with
///   `{scopeId}` (omitted when empty so the host answers `scope-required` with
///   its candidate scopes).
/// * [confirmForceStop] → `agent.conversation.force.confirm` with
///   `{scopeId, confirmationToken, confirmed}`.
///
/// All three are schema-declared `inFlightControl: true` methods, so they are
/// never queued behind bulk output. The answers are the bounded shapes
/// [WorkStopResult], [ForceStopPreview] and [ForceStopConfirmation] project.
///
/// A client without an implementation stays fail closed: it reports
/// [WorkStopResult.unavailable] / [ForceStopPreview.unavailable] /
/// [ForceStopConfirmation.unavailable] and never fabricates a stopped task.
abstract interface class WorkControlGateway {
  /// Requests a manual stop for exactly one durable work identity.
  Future<WorkStopResult> stopWork(WorkStopRequest request);

  /// Reads the force-stop consequences of one owned process scope. Sends no
  /// signal and terminates nothing.
  Future<ForceStopPreview> previewForceStop({String scopeId = ''});

  /// Confirms one previewed force stop. [confirmed] false means the user
  /// declined and the host must send no signal.
  Future<ForceStopConfirmation> confirmForceStop({
    required String scopeId,
    required String confirmationToken,
    required bool confirmed,
  });
}

/// Fail-closed control lane: every answer states that this client cannot reach
/// a native owner, so no surface can present an unconfirmed stop as done.
final class UnavailableWorkControlGateway implements WorkControlGateway {
  const UnavailableWorkControlGateway();

  @override
  Future<WorkStopResult> stopWork(WorkStopRequest request) async =>
      const WorkStopResult.unavailable();

  @override
  Future<ForceStopPreview> previewForceStop({String scopeId = ''}) async =>
      const ForceStopPreview.unavailable();

  @override
  Future<ForceStopConfirmation> confirmForceStop({
    required String scopeId,
    required String confirmationToken,
    required bool confirmed,
  }) async => const ForceStopConfirmation.unavailable();
}
