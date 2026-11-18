import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/conversation_execution.dart';
import 'package:licoup/src/contracts/conversation_execution_port.dart';
import 'package:licoup/src/presentation/conversation/conversation_execution_projection.dart';

/// Owns only renderer subscriptions. Execution state remains in the existing
/// application observer; closing a surface detaches that observer alone.
final class ConversationExecutionProjectionProducer
    implements ProjectionSource<ConversationExecutionProjection> {
  ConversationExecutionProjectionProducer(this._reader);

  final ConversationExecutionReader? _reader;
  final _views = <ConversationExecutionViewId, _ExecutionView>{};
  final _changes =
      StreamController<
        ProjectionUpdate<ConversationExecutionProjection>
      >.broadcast(sync: true);
  var _current = ConversationExecutionProjection();
  bool _closed = false;

  @override
  ConversationExecutionProjection get current => _current;

  @override
  Stream<ProjectionUpdate<ConversationExecutionProjection>> get changes =>
      _changes.stream;

  void open(
    ConversationExecutionViewId viewId,
    ConversationExecutionReference reference, {
    TraceContext? trace,
  }) {
    if (_closed || _views.containsKey(viewId)) {
      return;
    }
    final observation = _reader?.observe(reference);
    final view = _ExecutionView(observation);
    _views[viewId] = view;
    view.subscription = observation?.changes.listen((_) {
      if (!_closed && identical(_views[viewId], view)) {
        _publish();
      }
    });
    _publish(trace: trace);
  }

  void dismiss(ConversationExecutionViewId viewId, {TraceContext? trace}) {
    final view = _views.remove(viewId);
    if (view == null) {
      return;
    }
    view.dispose();
    _publish(trace: trace);
  }

  void _publish({TraceContext? trace}) {
    if (_closed) {
      return;
    }
    _current = ConversationExecutionProjection(
      views: {
        for (final entry in _views.entries)
          entry.key:
              entry.value.observation?.snapshot ??
              const ConversationExecutionState(loading: false),
      },
    );
    _changes.add(ProjectionUpdate(_current, trace: trace));
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final view in _views.values) {
      view.dispose();
    }
    _views.clear();
    _current = ConversationExecutionProjection();
    await _changes.close();
  }
}

final class _ExecutionView {
  _ExecutionView(this.observation);

  final ConversationExecutionObservation? observation;
  StreamSubscription<ConversationExecutionState>? subscription;

  void dispose() {
    unawaited(subscription?.cancel());
    observation?.dispose();
  }
}
