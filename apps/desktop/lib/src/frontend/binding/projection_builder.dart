import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projection_telemetry_scope.dart';

typedef ProjectionSelector<T, S> = S Function(T projection);
typedef SelectedProjectionWidgetBuilder<S> =
    Widget Function(BuildContext context, S selected);

final class ProjectionBuilder<T, S> extends StatefulWidget {
  const ProjectionBuilder({
    super.key,
    required this.source,
    required this.select,
    required this.builder,
  });

  final ProjectionSource<T> source;
  final ProjectionSelector<T, S> select;
  final SelectedProjectionWidgetBuilder<S> builder;

  @override
  State<ProjectionBuilder<T, S>> createState() =>
      _ProjectionBuilderState<T, S>();
}

final class _ProjectionBuilderState<T, S>
    extends State<ProjectionBuilder<T, S>> {
  StreamSubscription<ProjectionUpdate<T>>? _subscription;
  ProjectionReceiptObserver? _telemetry;
  final List<TraceContext> _pendingFrameTraces = [];
  late S _selected;

  @override
  void initState() {
    super.initState();
    _subscribeAndRead();
  }

  @override
  void didUpdateWidget(ProjectionBuilder<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _subscription?.cancel();
      _subscribeAndRead();
    } else if (!identical(oldWidget.select, widget.select)) {
      _selected = widget.select(widget.source.current);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _telemetry = ProjectionTelemetryScope.maybeOf(context);
  }

  void _subscribeAndRead() {
    _subscription = widget.source.changes.listen(_handleProjection);
    _selected = widget.select(widget.source.current);
  }

  void _handleProjection(ProjectionUpdate<T> update) {
    final next = widget.select(update.value);
    if (next == _selected) return;
    final telemetry = _telemetry;
    if (telemetry != null) {
      _pendingFrameTraces.add(telemetry.projectionReceived(update.trace));
    }
    setState(() => _selected = next);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final telemetry = _telemetry;
    if (telemetry != null && _pendingFrameTraces.isNotEmpty) {
      final traces = List<TraceContext>.of(_pendingFrameTraces);
      _pendingFrameTraces.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final frameBuildStart =
            WidgetsBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
        for (final trace in traces) {
          telemetry.projectionFrameConsumed(
            trace,
            frameBuildStartMicroseconds: frameBuildStart,
          );
        }
      }, debugLabel: 'ProjectionBuilder.firstConsumedFrame');
    }
    return widget.builder(context, _selected);
  }
}
