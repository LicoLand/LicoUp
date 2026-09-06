import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

abstract interface class ProjectionReceiptObserver {
  TraceContext projectionReceived(TraceContext? trace);

  void projectionFrameConsumed(
    TraceContext trace, {
    required int frameBuildStartMicroseconds,
  });
}

/// Renderer-local injection point for causal receipt instrumentation.
final class ProjectionTelemetryScope extends InheritedWidget {
  const ProjectionTelemetryScope({
    super.key,
    required this.observer,
    required super.child,
  });

  final ProjectionReceiptObserver observer;

  static ProjectionReceiptObserver? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ProjectionTelemetryScope>()
      ?.observer;

  @override
  bool updateShouldNotify(ProjectionTelemetryScope oldWidget) =>
      !identical(oldWidget.observer, observer);
}
