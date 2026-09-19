import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'author_support.dart';

final class ProgressState {
  const ProgressState({
    required this.completed,
    required this.label,
    this.error,
  });

  final double completed;
  final String label;
  final ExampleError? error;
}

/// Plain inputs are the stable value a renderer can consume.
final class ProgressInputs {
  const ProgressInputs({required this.scope, required this.state});

  final ResourceScope scope;
  final ProgressState state;

  ExampleError? get error => state.error;
}

sealed class ProgressAction {
  const ProgressAction();
}

final class CancelProgress extends ProgressAction {
  const CancelProgress();
}

/// Actions stay typed while their origin keeps the originating scope pinned.
final class ProgressActions {
  const ProgressActions({required this.origin, required this.cancel});

  final ActionOrigin origin;
  final FutureOr<void> Function() cancel;
}

final class ProgressActionLog {
  bool cancelled = false;
}

final class ProgressExampleResult {
  const ProgressExampleResult({
    required this.inputs,
    required this.actions,
    required this.firstMemberCommitted,
    required this.groupCommitted,
    required this.installedMemberCount,
    required this.actionLog,
  });

  final ProgressInputs inputs;
  final ProgressActions actions;
  final bool firstMemberCommitted;
  final bool groupCommitted;
  final int installedMemberCount;
  final ProgressActionLog actionLog;
}

ProgressExampleResult buildProgressExample() {
  final scope = const ResourceScope('conversation:synthetic');
  final resource = ResourceKey(scope: scope, stableKey: 'run-1');
  final progressFields = ResourceFieldGroup<ProgressState>(
    resource: resource,
    name: 'progress',
  );
  final statusFields = ResourceFieldGroup<ProgressState>(
    resource: resource,
    name: 'status',
  );
  final position = const SourcePosition(
    epoch: SourceEpoch('progress-epoch'),
    version: SourceVersion(1),
  );
  final group = ConsistencyGroup(
    id: const ConsistencyGroupId(
      'progress-group-1',
      source: SourceIdentity(
        scope: ResourceScope('conversation:synthetic'),
        stableKey: 'progress-source',
      ),
    ),
    position: position,
    changed: <ChangedFieldGroup>[
      ChangedFieldGroup.of(progressFields),
      ChangedFieldGroup.of(statusFields),
    ],
  );
  final error = ExampleError(
    attribution: ExampleErrorAttribution(
      scope: scope,
      resource: resource,
      operation: 'progress.render',
    ),
    message: 'The synthetic progress source is waiting for another update.',
  );
  final state = ProgressState(
    completed: 0.75,
    label: 'Three quarters complete',
    error: error,
  );
  final progressSnapshot = ResourceSnapshot<ProgressState>(
    fieldGroup: progressFields,
    epoch: position.epoch,
    version: position.version,
    value: state,
    consistencyGroup: group,
  );
  final statusSnapshot = ResourceSnapshot<ProgressState>(
    fieldGroup: statusFields,
    epoch: position.epoch,
    version: position.version,
    value: state,
    consistencyGroup: group,
  );
  final progressRequest = PreparationRequest<ProgressState>.fromSnapshot(
    snapshot: progressSnapshot,
    generation: const RequestGeneration(1),
  );
  final statusRequest = PreparationRequest<ProgressState>.fromSnapshot(
    snapshot: statusSnapshot,
    generation: const RequestGeneration(1),
  );
  final installer = AtomicExampleInstaller<ProgressState>(group);

  final firstMemberCommitted = installer.install(
    PreparedResource<ProgressState>(request: progressRequest, value: state),
    PreparationAcceptance<ProgressState>(request: progressRequest),
  );
  final groupCommitted = installer.install(
    PreparedResource<ProgressState>(request: statusRequest, value: state),
    PreparationAcceptance<ProgressState>(request: statusRequest),
  );

  final actionLog = ProgressActionLog();
  final callback = CallbackActions<ProgressAction>(
    origin: ActionOrigin(scope: scope, resource: resource),
    onDispatch: (action, origin) {
      if (origin.scope != scope) {
        throw StateError('progress action crossed its originating scope');
      }
      if (action is CancelProgress) actionLog.cancelled = true;
    },
  );
  final actions = ProgressActions(
    origin: callback.origin,
    cancel: () => callback.dispatch(const CancelProgress()),
  );
  final inputs = ProgressInputs(scope: scope, state: state);

  return ProgressExampleResult(
    inputs: inputs,
    actions: actions,
    firstMemberCommitted: firstMemberCommitted,
    groupCommitted: groupCommitted,
    installedMemberCount: installer.installed.length,
    actionLog: actionLog,
  );
}

void main() {
  final result = buildProgressExample();
  if (result.firstMemberCommitted ||
      !result.groupCommitted ||
      result.installedMemberCount != 2) {
    throw StateError('progress consistency group did not install atomically');
  }

  result.actions.cancel();
  if (!result.actionLog.cancelled) {
    throw StateError('typed progress action was not delivered');
  }
  final error = result.inputs.error;
  if (error == null ||
      error.attribution.scope != result.inputs.scope ||
      error.attribution.resource == null) {
    throw StateError('progress error lost its scope or resource attribution');
  }

  print('progress: ${result.inputs.state.completed}');
  print('group members installed: ${result.installedMemberCount}');
  print('error scope: ${error.attribution.scope.value}');
}
