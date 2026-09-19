import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/misc.dart' show Override, ProviderListenable;

final class ProgressInputs {
  const ProgressInputs({
    required this.scope,
    required this.completed,
    required this.label,
  });

  final ResourceScope scope;
  final double completed;
  final String label;
}

final class FilteredListInputs {
  FilteredListInputs({
    required this.scope,
    required this.query,
    required Iterable<String> items,
  }) : items = List<String>.unmodifiable(items);

  final ResourceScope scope;
  final String query;
  final List<String> items;
}

final class ValidatedInputInputs {
  const ValidatedInputInputs({
    required this.scope,
    required this.text,
    required this.error,
  });

  final ResourceScope scope;
  final String text;
  final String? error;
}

/// The source is synthetic, but it obeys the same initial-plus-changes port
/// that a real application source must implement.
final class SyntheticSource<T> implements PresentationSource<T> {
  const SyntheticSource({required this.fieldGroup, required this.snapshot});

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final ResourceSnapshot<T> snapshot;

  @override
  Future<SourceObservation<T>> open() async => SourceObservation<T>(
    initial: snapshot,
    changes: Stream<SourceChange<T>>.empty(),
  );
}

final class _UnavailableSource<T> implements PresentationSource<T> {
  const _UnavailableSource(this.fieldGroup);

  @override
  final ResourceFieldGroup<T> fieldGroup;

  @override
  Future<SourceObservation<T>> open() => Future<SourceObservation<T>>.error(
    StateError('the source must be supplied by application composition'),
  );
}

final class _Entry<T> implements PresentationProviderEntry<T> {
  const _Entry({required this.resource, required this.listenable});

  @override
  final ResourceFieldGroup<T> resource;

  @override
  final ProviderListenable<AsyncValue<ResourceSnapshot<T>>> listenable;
}

final progressResource = ResourceFieldGroup<ProgressInputs>(
  resource: ResourceKey(
    scope: const ResourceScope('progress:synthetic'),
    stableKey: 'run-1',
  ),
  name: 'inputs',
);

final listResource = ResourceFieldGroup<FilteredListInputs>(
  resource: ResourceKey(
    scope: const ResourceScope('list:synthetic'),
    stableKey: 'items',
  ),
  name: 'inputs',
);

final validatedInputResource = ResourceFieldGroup<ValidatedInputInputs>(
  resource: ResourceKey(
    scope: const ResourceScope('settings:synthetic'),
    stableKey: 'display-name',
  ),
  name: 'inputs',
);

final _progressPosition = const SourcePosition(
  epoch: SourceEpoch('progress-epoch'),
  version: SourceVersion(1),
);
final _listPosition = const SourcePosition(
  epoch: SourceEpoch('list-epoch'),
  version: SourceVersion(1),
);
final _validatedInputPosition = const SourcePosition(
  epoch: SourceEpoch('validated-input-epoch'),
  version: SourceVersion(1),
);

ConsistencyGroup _groupFor<T>(
  ResourceFieldGroup<T> fieldGroup,
  SourcePosition position,
  String sourceKey,
) {
  return ConsistencyGroup(
    id: ConsistencyGroupId(
      '$sourceKey-group',
      source: SourceIdentity(
        scope: fieldGroup.resource.scope,
        stableKey: sourceKey,
      ),
    ),
    position: position,
    changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
  );
}

final _progressGroup = _groupFor(
  progressResource,
  _progressPosition,
  'progress-source',
);
final _listGroup = _groupFor(listResource, _listPosition, 'list-source');
final _validatedInputGroup = _groupFor(
  validatedInputResource,
  _validatedInputPosition,
  'validated-input-source',
);

final syntheticProgressSource = SyntheticSource<ProgressInputs>(
  fieldGroup: progressResource,
  snapshot: ResourceSnapshot<ProgressInputs>(
    fieldGroup: progressResource,
    epoch: _progressPosition.epoch,
    version: _progressPosition.version,
    value: ProgressInputs(
      scope: progressResource.resource.scope,
      completed: 0.75,
      label: 'Three quarters complete',
    ),
    consistencyGroup: _progressGroup,
  ),
);

final syntheticListSource = SyntheticSource<FilteredListInputs>(
  fieldGroup: listResource,
  snapshot: ResourceSnapshot<FilteredListInputs>(
    fieldGroup: listResource,
    epoch: _listPosition.epoch,
    version: _listPosition.version,
    value: FilteredListInputs(
      scope: listResource.resource.scope,
      query: 'ap',
      items: const <String>['Apple', 'Apricot'],
    ),
    consistencyGroup: _listGroup,
  ),
);

final syntheticValidatedInputSource = SyntheticSource<ValidatedInputInputs>(
  fieldGroup: validatedInputResource,
  snapshot: ResourceSnapshot<ValidatedInputInputs>(
    fieldGroup: validatedInputResource,
    epoch: _validatedInputPosition.epoch,
    version: _validatedInputPosition.version,
    value: ValidatedInputInputs(
      scope: validatedInputResource.resource.scope,
      text: 'lic',
      error: 'Display names need at least four characters.',
    ),
    consistencyGroup: _validatedInputGroup,
  ),
);

/// Source ports are composition inputs. The current runtime entry is a
/// listenable; the example supplies its typed snapshot provider as an
/// override until a later runtime slice connects live source observation.
final progressSourceProvider = Provider<PresentationSource<ProgressInputs>>(
  (_) => _UnavailableSource<ProgressInputs>(progressResource),
);
final listSourceProvider = Provider<PresentationSource<FilteredListInputs>>(
  (_) => _UnavailableSource<FilteredListInputs>(listResource),
);
final validatedInputSourceProvider =
    Provider<PresentationSource<ValidatedInputInputs>>(
      (_) => _UnavailableSource<ValidatedInputInputs>(validatedInputResource),
    );

final progressSnapshotProvider =
    Provider<AsyncValue<ResourceSnapshot<ProgressInputs>>>(
      (_) => AsyncValue<ResourceSnapshot<ProgressInputs>>.error(
        StateError('override progressSnapshotProvider in composition'),
        StackTrace.current,
      ),
    );
final listSnapshotProvider =
    Provider<AsyncValue<ResourceSnapshot<FilteredListInputs>>>(
      (_) => AsyncValue<ResourceSnapshot<FilteredListInputs>>.error(
        StateError('override listSnapshotProvider in composition'),
        StackTrace.current,
      ),
    );
final validatedInputSnapshotProvider =
    Provider<AsyncValue<ResourceSnapshot<ValidatedInputInputs>>>(
      (_) => AsyncValue<ResourceSnapshot<ValidatedInputInputs>>.error(
        StateError('override validatedInputSnapshotProvider in composition'),
        StackTrace.current,
      ),
    );

final progressEntryProvider =
    Provider<PresentationProviderEntry<ProgressInputs>>(
      (_) => _Entry<ProgressInputs>(
        resource: progressResource,
        listenable: progressSnapshotProvider,
      ),
    );
final listEntryProvider =
    Provider<PresentationProviderEntry<FilteredListInputs>>(
      (_) => _Entry<FilteredListInputs>(
        resource: listResource,
        listenable: listSnapshotProvider,
      ),
    );
final validatedInputEntryProvider =
    Provider<PresentationProviderEntry<ValidatedInputInputs>>(
      (_) => _Entry<ValidatedInputInputs>(
        resource: validatedInputResource,
        listenable: validatedInputSnapshotProvider,
      ),
    );

sealed class AssemblyAction {
  const AssemblyAction();
}

final class CancelProgress extends AssemblyAction {
  const CancelProgress();
}

final class SelectListItem extends AssemblyAction {
  const SelectListItem(this.stableKey);

  final String stableKey;
}

final class SubmitValidatedInput extends AssemblyAction {
  const SubmitValidatedInput();
}

Future<void> main() async {
  final container = ProviderContainer(
    overrides: <Override>[
      progressSourceProvider.overrideWithValue(syntheticProgressSource),
      listSourceProvider.overrideWithValue(syntheticListSource),
      validatedInputSourceProvider.overrideWithValue(
        syntheticValidatedInputSource,
      ),
      progressSnapshotProvider.overrideWithValue(
        AsyncValue<ResourceSnapshot<ProgressInputs>>.data(
          syntheticProgressSource.snapshot,
        ),
      ),
      listSnapshotProvider.overrideWithValue(
        AsyncValue<ResourceSnapshot<FilteredListInputs>>.data(
          syntheticListSource.snapshot,
        ),
      ),
      validatedInputSnapshotProvider.overrideWithValue(
        AsyncValue<ResourceSnapshot<ValidatedInputInputs>>.data(
          syntheticValidatedInputSource.snapshot,
        ),
      ),
    ],
  );

  try {
    final progressEntry = container.read(progressEntryProvider);
    final listEntry = container.read(listEntryProvider);
    final inputEntry = container.read(validatedInputEntryProvider);
    final progress = _readSnapshot(container, progressEntry);
    final list = _readSnapshot(container, listEntry);
    final input = _readSnapshot(container, inputEntry);

    if (progress.value.completed != 0.75 ||
        list.value.items.length != 2 ||
        input.value.error == null) {
      throw StateError('typed provider overrides were not installed');
    }
    if (progress.consistencyGroup != _progressGroup ||
        list.consistencyGroup != _listGroup ||
        input.consistencyGroup != _validatedInputGroup) {
      throw StateError('provider assembly lost consistency-group identity');
    }

    final opened = await container.read(progressSourceProvider).open();
    if (opened.initial != syntheticProgressSource.snapshot) {
      throw StateError('synthetic source did not open at its initial snapshot');
    }

    var dispatched = 0;
    final actions = CallbackActions<AssemblyAction>(
      origin: ActionOrigin(
        scope: progressResource.resource.scope,
        resource: progressResource.resource,
      ),
      onDispatch: (action, origin) {
        if (origin.scope != progressResource.resource.scope) {
          throw StateError('assembly action crossed its originating scope');
        }
        switch (action) {
          case CancelProgress():
          case SelectListItem():
          case SubmitValidatedInput():
            dispatched++;
        }
      },
    );
    await actions.dispatch(const CancelProgress());
    if (dispatched != 1) {
      throw StateError('typed assembly action was not delivered');
    }

    print('entries: 3');
    print('progress revision: ${progress.version.value}');
    print('list rows: ${list.value.items.length}');
    print('validated input error: ${input.value.error}');
  } finally {
    container.dispose();
  }
}

ResourceSnapshot<T> _readSnapshot<T>(
  ProviderContainer container,
  PresentationProviderEntry<T> entry,
) {
  final state = container.read(entry.listenable);
  return state.when(
    data: (snapshot) => snapshot,
    error: (error, stackTrace) =>
        throw StateError('snapshot provider failed: $error'),
    loading: () => throw StateError('snapshot provider is still loading'),
  );
}
