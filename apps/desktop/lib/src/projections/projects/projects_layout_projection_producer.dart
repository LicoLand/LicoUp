import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/projects/controller/project_layout_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

/// Projects the local arrangement into one renderer value.
///
/// The producer reads a state owner that holds no gateway, so a change it
/// publishes can only be a position or an order.
final class ProjectsLayoutProjectionProducer
    implements ProjectionSource<ProjectsLayoutState> {
  ProjectsLayoutProjectionProducer({
    required ProjectLayoutController controller,
  }) : _controller = controller,
       _current = controller.layout {
    _subscription = controller.changes.listen(_handleChange);
  }

  final ProjectLayoutController _controller;
  final StreamController<ProjectionUpdate<ProjectsLayoutState>> _changes =
      StreamController<ProjectionUpdate<ProjectsLayoutState>>.broadcast(
        sync: true,
      );
  late final StreamSubscription<ApplicationChange> _subscription;
  ProjectsLayoutState _current;
  bool _disposed = false;

  @override
  ProjectsLayoutState get current => _current;

  @override
  Stream<ProjectionUpdate<ProjectsLayoutState>> get changes => _changes.stream;

  void _handleChange(ApplicationChange change) =>
      _publish(trace: _trace(change.cause));

  void _publish({TraceContext? trace}) {
    if (_disposed) return;
    final next = _controller.layout;
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate<ProjectsLayoutState>(next, trace: trace));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await closeBroadcastController(_changes);
  }
}

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
