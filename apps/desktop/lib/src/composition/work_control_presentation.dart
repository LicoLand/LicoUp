import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/runtime_control/controller/work_control_controller.dart';
import 'package:licoup/src/contracts/presentation/work_control_models.dart';

/// Renderer-facing listenable over the application work-control controller.
///
/// The renderer needs a [Listenable] to rebuild a stop surface when the host
/// answer changes; this adapter forwards the controller's own change stream
/// and holds no state of its own.
final class WorkControlPresentation extends ChangeNotifier {
  WorkControlPresentation(this._controller) {
    _subscription = _controller.changes.listen((_) => notifyListeners());
  }

  final WorkControlController _controller;
  late final StreamSubscription<Object?> _subscription;

  /// The visible stage for work the caller still observes in flight.
  WorkStopStage stage({required bool observedActive}) =>
      _controller.stageFor(observedActive: observedActive);

  /// Short local reference for the last stop answer.
  String get stopDiagnosticReference => _controller.stopDiagnosticReference;

  /// Short local reference for the last force-stop answer.
  String get forceStopDiagnosticReference =>
      _controller.forceStopDiagnosticReference;

  bool get forceStopInFlight => _controller.busy;

  /// Reads the force-stop consequences. Sends no signal.
  Future<ForceStopPreview> previewForceStop({String scopeId = ''}) =>
      _controller.previewForceStop(scopeId: scopeId);

  /// Declines the shown force stop: nothing is sent.
  void declineForceStop() => _controller.declineForceStop();

  /// Confirms the exact previewed force stop with one native call.
  Future<ForceStopConfirmation> confirmForceStop() =>
      _controller.confirmForceStop();

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
