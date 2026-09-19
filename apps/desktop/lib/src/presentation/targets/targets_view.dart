import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/targets/targets_intent.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';
import 'package:licoup/src/presentation/targets/targets_resources.dart';

/// Narrow renderer-facing inputs for the target catalog view.
final class TargetsCatalogInputs {
  const TargetsCatalogInputs({
    required this.scope,
    required this.targets,
    required this.manualTargetOptions,
    required this.phase,
    this.notice,
  });

  factory TargetsCatalogInputs.fromProjection(TargetsProjection projection) =>
      TargetsCatalogInputs(
        scope: targetsPresentationScope,
        targets: projection.targets,
        manualTargetOptions: projection.manualTargetOptions,
        phase: projection.phase,
        notice: projection.notice,
      );

  final ResourceScope scope;
  final List<TargetProjectionItem> targets;
  final List<ManualTargetOptionProjection> manualTargetOptions;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TargetsCatalogInputs &&
          other.scope == scope &&
          samePresentationList(other.targets, targets) &&
          samePresentationList(
            other.manualTargetOptions,
            manualTargetOptions,
          ) &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    scope,
    Object.hashAll(targets),
    Object.hashAll(manualTargetOptions),
    phase,
    notice,
  );
}

/// Narrow renderer actions for the target catalog. Every dispatch carries the
/// pinned originating scope so asynchronous failures stay attributable.
final class TargetsCatalogActions {
  const TargetsCatalogActions({
    required this.origin,
    required this.scan,
    required this.addManual,
    required this.select,
    required this.togglePinned,
    required this.inspect,
  });

  factory TargetsCatalogActions.fromIntents(IntentSink<TargetsIntent> intents) {
    const origin = ActionOrigin(
      scope: targetsPresentationScope,
      resource: targetsCatalogResource,
    );
    final channel = CallbackActions<TargetsIntent>(
      origin: origin,
      onDispatch: (intent, _) => intents.send(intent),
    );
    return TargetsCatalogActions(
      origin: origin,
      scan: ({bool force = false}) =>
          channel.dispatch(ScanTargets(force: force)),
      addManual:
          ({
            required String targetId,
            String configPath = '',
            String binaryPath = '',
            String historyRoot = '',
            String location = 'local',
            String host = '',
            int? port,
            String user = '',
            String remoteExecutable = '',
            String workingDirectory = '',
            String runtimeProtocol = '',
          }) => channel.dispatch(
            AddManualTarget(
              targetId: targetId,
              configPath: configPath,
              binaryPath: binaryPath,
              historyRoot: historyRoot,
              location: location,
              host: host,
              port: port,
              user: user,
              remoteExecutable: remoteExecutable,
              workingDirectory: workingDirectory,
              runtimeProtocol: runtimeProtocol,
            ),
          ),
      select: (targetId) => channel.dispatch(SelectTarget(targetId)),
      togglePinned: (targetId) =>
          channel.dispatch(ToggleTargetPinned(targetId)),
      inspect: (targetId) => channel.dispatch(InspectTarget(targetId)),
    );
  }

  final ActionOrigin origin;
  final FutureOr<void> Function({bool force}) scan;
  final FutureOr<void> Function({
    required String targetId,
    String configPath,
    String binaryPath,
    String historyRoot,
    String location,
    String host,
    int? port,
    String user,
    String remoteExecutable,
    String workingDirectory,
    String runtimeProtocol,
  })
  addManual;
  final FutureOr<void> Function(String targetId) select;
  final FutureOr<void> Function(String targetId) togglePinned;
  final FutureOr<void> Function(String targetId) inspect;
}
