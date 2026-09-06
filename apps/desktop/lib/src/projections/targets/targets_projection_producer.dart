import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class TargetsProjectionProducer
    implements ProjectionSource<TargetsProjection> {
  TargetsProjectionProducer({
    required TargetController controller,
    required String Function() readSelectedTargetId,
    required Iterable<ManualTargetOptionProjection> manualTargetOptions,
  }) : _controller = controller,
       _readSelectedTargetId = readSelectedTargetId,
       _manualTargetOptions = List.unmodifiable(manualTargetOptions),
       _current = _read(
         controller,
         readSelectedTargetId(),
         manualTargetOptions,
       ) {
    _subscription = controller.changes.listen(_handleChange);
  }

  final TargetController _controller;
  final String Function() _readSelectedTargetId;
  final List<ManualTargetOptionProjection> _manualTargetOptions;
  final StreamController<ProjectionUpdate<TargetsProjection>> _changes =
      StreamController<ProjectionUpdate<TargetsProjection>>.broadcast(
        sync: true,
      );
  late final StreamSubscription<ApplicationChange> _subscription;
  TargetsProjection _current;
  bool _disposed = false;

  @override
  TargetsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<TargetsProjection>> get changes => _changes.stream;

  void refreshSelection({TraceContext? trace}) => _publish(trace: trace);

  void _handleChange(ApplicationChange change) {
    _publish(trace: _trace(change.cause));
  }

  void _publish({TraceContext? trace}) {
    if (_disposed) return;
    final next = _read(
      _controller,
      _readSelectedTargetId(),
      _manualTargetOptions,
    );
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate(next, trace: trace));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await closeBroadcastController(_changes);
  }

  static TargetsProjection _read(
    TargetController controller,
    String selectedTargetId,
    Iterable<ManualTargetOptionProjection> manualTargetOptions,
  ) {
    final targets = controller.orderedConversationTargets(
      controller.targets.where((target) => target.visibleInClient),
    );
    final failure = controller.lastErrorCode;
    return TargetsProjection(
      targets: [
        for (final target in targets)
          TargetProjectionItem(
            id: target.target,
            name: target.label.trim().isEmpty ? target.target : target.label,
            typeLabel: target.kind,
            readinessLabel: target.status,
            detail: target.detail ?? '',
            locationLabel: target.location,
            configured: target.configured,
            pinned: controller.isConversationTargetPinned(target.target),
            selected: target.target == selectedTargetId,
          ),
      ],
      manualTargetOptions: manualTargetOptions,
      phase: failure.isNotEmpty
          ? PresentationPhase.failed
          : controller.isScanning || controller.isAdding
          ? PresentationPhase.loading
          : PresentationPhase.ready,
      notice: failure.isEmpty
          ? null
          : PresentationNotice(
              id: 'targets-failure',
              title: 'Targets',
              message: failure,
              severity: PresentationNoticeSeverity.error,
              reasonCode: failure,
            ),
    );
  }
}

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
