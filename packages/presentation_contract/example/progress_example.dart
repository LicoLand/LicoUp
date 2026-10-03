import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'author_support.dart';

/// Prepared payload of one block, as a worker would hand it to a view.
final class ProgressFragment {
  const ProgressFragment({required this.text, required this.completed});

  final String text;
  final double completed;
}

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
  const ProgressInputs({
    required this.scope,
    required this.state,
    required this.prepared,
  });

  final ResourceScope scope;
  final ProgressState state;

  /// The prepared value the inputs were read from, prefix and tail together.
  final PreparedValue<ProgressFragment> prepared;

  ExampleError? get error => state.error;
}

/// Ordinary data for the third-party chart primitive: no DSL, no provider.
final class ProgressChartSeries {
  const ProgressChartSeries({
    required this.metric,
    required this.label,
    required this.unit,
  });

  final String metric;
  final String label;
  final String unit;
}

final class ProgressChartInputs {
  const ProgressChartInputs({required this.title, required this.series});

  final String title;
  final List<ProgressChartSeries> series;
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
    required this.chart,
    required this.firstMemberStaged,
    required this.groupInstalled,
    required this.installedMemberCount,
    required this.revokedOutcome,
    required this.revokedInstalledCount,
    required this.actionLog,
  });

  final ProgressInputs inputs;
  final ProgressActions actions;
  final DeclarativeInput<ProgressChartInputs, ProgressAction> chart;
  final GroupInstallOutcome firstMemberStaged;
  final GroupInstallOutcome groupInstalled;
  final int installedMemberCount;
  final GroupInstallOutcome revokedOutcome;
  final int revokedInstalledCount;
  final ProgressActionLog actionLog;
}

/// Builds the progress example without Flutter, Riverpod, or a live facade.
ProgressExampleResult buildProgressExample() {
  final scope = const ResourceScope('conversation:synthetic');
  final resource = ResourceKey(scope: scope, stableKey: 'run-1');
  final progressFields = ResourceFieldGroup<ProgressFragment>(
    resource: resource,
    name: 'progress',
  );
  final statusFields = ResourceFieldGroup<ProgressFragment>(
    resource: resource,
    name: 'status',
  );
  final position = const SourcePosition(
    epoch: SourceEpoch('progress-epoch'),
    version: SourceVersion(1),
  );

  // One source revision: the settled ledger block and the still-growing tail.
  final content = ContentRevision(
    resource: resource,
    position: position,
    blocks: <SourceBlock>[
      SourceBlock(
        id: const BlockId('ledger'),
        version: const BlockVersion(2),
        text: SourceTextReference(
          resource: resource,
          position: position,
          range: const SourceTextRange(start: 0, end: 32),
        ),
        isSealed: true,
      ),
      SourceBlock(
        id: const BlockId('tail'),
        version: const BlockVersion(4),
        text: SourceTextReference(
          resource: resource,
          position: position,
          range: const SourceTextRange(start: 32, end: 48),
        ),
      ),
    ],
  );
  final parserVersion = const ParserVersion('progress-markdown@1');
  final syntaxConfig = SyntaxConfig(
    revision: 'progress-syntax@1',
    features: const <String>['tables'],
  );
  final key = PreparationKey(
    parserVersion: parserVersion,
    syntaxConfig: syntaxConfig,
    content: content,
  );
  final prepared = PreparedValue<ProgressFragment>.fromBlocks(
    key: key,
    blocks: <PreparedBlock<ProgressFragment>>[
      PreparedBlock<ProgressFragment>(
        block: content.blocks[0],
        value: const ProgressFragment(text: 'ledger settled', completed: 0.75),
      ),
      PreparedBlock<ProgressFragment>(
        block: content.blocks[1],
        value: const ProgressFragment(text: 'settling tail', completed: 0.75),
      ),
    ],
    referencedInputs: <PreparedInputReference>[
      PreparedInputReference(resource: resource, name: 'window'),
    ],
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
  final cause = PreparationCause(
    trigger: PreparationTrigger.blocksChanged,
    scope: PreparationScope.incremental,
    changed: <BlockId>{content.blocks[1].id},
  );
  PreparedResource<ProgressFragment> member(
    ResourceFieldGroup<ProgressFragment> fields,
  ) {
    final fragment = prepared.blocks.last.value;
    final snapshot = ResourceSnapshot<ProgressFragment>(
      fieldGroup: fields,
      epoch: position.epoch,
      version: position.version,
      value: fragment,
      consistencyGroup: group,
    );
    return PreparedResource<ProgressFragment>(
      request: PreparationRequest<ProgressFragment>.fromSnapshot(
        snapshot: snapshot,
        generation: const RequestGeneration(1),
        cause: cause,
      ),
      value: fragment,
    );
  }

  final install = ConsistencyGroupInstall<ProgressFragment>(group);
  final progressMember = member(progressFields);
  final statusMember = member(statusFields);
  final firstMemberStaged = install.offer(
    progressMember,
    acceptMember(progressMember),
  );
  final groupInstalled = install.offer(
    statusMember,
    acceptMember(statusMember),
  );

  // A revoked group hands out nothing: the staged member is dropped at once,
  // and the member that arrives later is refused instead of completing it.
  final revoked = ConsistencyGroupInstall<ProgressFragment>(group);
  final revokedProgress = member(progressFields);
  final revokedStatus = member(statusFields);
  revoked.offer(revokedProgress, acceptMember(revokedProgress));
  revoked.revoke();
  final revokedOutcome = revoked.offer(
    revokedStatus,
    acceptMember(revokedStatus),
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
    completed: prepared.mutableTail.isEmpty
        ? prepared.immutablePrefix.first.value.completed
        : prepared.mutableTail.first.value.completed,
    label: prepared.immutablePrefix.first.value.text,
    error: error,
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

  // The chart is declared from ordinary values; the shell compiles the
  // primitive, and this contribution never touches the source lifecycle.
  final chart = DeclarativeInput<ProgressChartInputs, ProgressAction>(
    contributionId: 'vendor.example.progress-chart',
    primitive: DeclarativePrimitive.chart,
    resource: resource,
    inputs: ProgressChartInputs(
      title: 'Run progress',
      series: const <ProgressChartSeries>[
        ProgressChartSeries(
          metric: 'vendor.example/progress',
          label: 'Completed',
          unit: 'fraction',
        ),
      ],
    ),
    actions: callback,
    position: position,
  );

  return ProgressExampleResult(
    inputs: ProgressInputs(scope: scope, state: state, prepared: prepared),
    actions: actions,
    chart: chart,
    firstMemberStaged: firstMemberStaged,
    groupInstalled: groupInstalled,
    installedMemberCount: install.installed.length,
    revokedOutcome: revokedOutcome,
    revokedInstalledCount: revoked.installed.length,
    actionLog: actionLog,
  );
}

void main() {
  final result = buildProgressExample();
  if (result.firstMemberStaged != GroupInstallOutcome.staged ||
      result.groupInstalled != GroupInstallOutcome.installed ||
      result.installedMemberCount != 2) {
    throw StateError('progress consistency group did not install atomically');
  }
  if (result.revokedOutcome != GroupInstallOutcome.rejected ||
      result.revokedInstalledCount != 0) {
    throw StateError('revoked group still handed out prepared members');
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
  final missing = result.chart.unavailableGiven(<DeclarativePrimitive>[
    DeclarativePrimitive.form,
    DeclarativePrimitive.text,
    DeclarativePrimitive.progress,
  ]);
  if (missing == null ||
      result.chart.unavailableGiven(<DeclarativePrimitive>[
            DeclarativePrimitive.chart,
          ]) !=
          null) {
    throw StateError('chart contribution ignored the shell primitive set');
  }

  print('progress: ${result.inputs.state.completed}');
  print('prepared tail blocks: ${result.inputs.prepared.mutableTail.length}');
  print('group members installed: ${result.installedMemberCount}');
  print('chart local state: ${missing.contributionId}');
  print('error scope: ${error.attribution.scope.value}');
}
