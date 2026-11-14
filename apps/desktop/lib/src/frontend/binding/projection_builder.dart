import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projection_binding.dart';
import 'package:licoup/src/frontend/binding/projection_telemetry_scope.dart';

export 'package:licoup/src/frontend/binding/projection_binding.dart'
    show ProjectionSelector, ProjectionCommit, ShellRegionClass;

typedef SelectedProjectionWidgetBuilder<S> =
    Widget Function(BuildContext context, S selected);

/// Binds one shell region to one projection source.
///
/// A page, a dialog, a sidebar and a background tab all render through this
/// widget, so none of them implements its own listening, race handling or
/// cleanup; the lifecycle belongs to [ProjectionBinding]. A region only
/// declares its source, the slice it renders ([select]) and its view
/// ([builder]).
///
/// The region is a subtree boundary for invalidation: the selector decides
/// what this region depends on, and only a changed selected value rebuilds it.
/// A background tab sets [active] to false, keeps rendering its last committed
/// value, and closes its gap on reattach.
final class ProjectionBuilder<T, S> extends StatefulWidget {
  const ProjectionBuilder({
    super.key,
    required this.source,
    required this.select,
    required this.builder,
    this.active = true,
    this.region = ShellRegionClass.business,
  });

  final ProjectionSource<T> source;
  final ProjectionSelector<T, S> select;
  final SelectedProjectionWidgetBuilder<S> builder;

  /// Whether the region observes its source now.
  ///
  /// A background tab that is not visible sets this to false: the widget stops
  /// observing the source, keeps its last committed value, and re-reads the
  /// source when it becomes active again.
  final bool active;

  /// The region's lifecycle class. See [ShellRegionClass].
  final ShellRegionClass region;

  @override
  State<ProjectionBuilder<T, S>> createState() =>
      _ProjectionBuilderState<T, S>();
}

final class _ProjectionBuilderState<T, S>
    extends State<ProjectionBuilder<T, S>> {
  ProjectionBinding<T, S>? _binding;
  ProjectionReceiptObserver? _telemetry;
  final List<TraceContext> _pendingFrameTraces = [];
  late S _selected;

  @override
  void initState() {
    super.initState();
    final binding = ProjectionBinding<T, S>(
      source: widget.source,
      select: widget.select,
      region: widget.region,
      onValue: _handleValue,
    );
    binding.activate();
    if (!widget.active) binding.deactivate();
    _binding = binding;
    _selected = binding.value;
  }

  @override
  void didUpdateWidget(ProjectionBuilder<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final binding = _binding;
    if (binding == null) return;
    if (!identical(oldWidget.source, widget.source)) {
      // A trace of a superseded source must never be attributed to the region
      // that replaced it.
      _pendingFrameTraces.clear();
      binding.rebind(source: widget.source, select: widget.select);
    } else if (!identical(oldWidget.select, widget.select)) {
      binding.rebind(select: widget.select);
    }
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        binding.activate();
      } else {
        binding.deactivate();
      }
    }
    _selected = binding.value;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _telemetry = ProjectionTelemetryScope.maybeOf(context);
  }

  void _handleValue(S value, TraceContext? cause) {
    final telemetry = _telemetry;
    if (cause != null && telemetry != null) {
      _pendingFrameTraces.add(telemetry.projectionReceived(cause));
    }
    setState(() => _selected = value);
  }

  @override
  void dispose() {
    final binding = _binding;
    _binding = null;
    if (binding != null) {
      // The region's own disposal is terminal; the cancel settles on the
      // microtask queue like every other release in the lifecycle.
      unawaited(binding.dispose());
    }
    _pendingFrameTraces.clear();
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
