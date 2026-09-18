import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:test/test.dart';

final class _Entry implements PresentationProviderEntry<String> {
  _Entry(this.resource, ResourceSnapshot<String> snapshot)
    : listenable = Provider<AsyncValue<ResourceSnapshot<String>>>(
        (ref) => AsyncValue<ResourceSnapshot<String>>.data(snapshot),
      );

  @override
  final ResourceFieldGroup<String> resource;

  @override
  final ProviderListenable<AsyncValue<ResourceSnapshot<String>>> listenable;
}

final class _TestSource<T> implements PresentationSource<T> {
  _TestSource({required this.fieldGroup, required this.initial}) {
    changes = StreamController<SourceChange<T>>.broadcast(
      onCancel: () => cancelCount++,
    );
  }

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final ResourceSnapshot<T> initial;
  late final StreamController<SourceChange<T>> changes;
  int openCount = 0;
  int cancelCount = 0;

  @override
  Future<SourceObservation<T>> open() async {
    openCount++;
    return SourceObservation<T>(initial: initial, changes: changes.stream);
  }

  void emit(SourceChange<T> change) => changes.add(change);

  Future<void> close() => changes.close();
}

Future<void> _settle() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ResourceSnapshot<T> _snapshot<T>({
  required ResourceFieldGroup<T> fieldGroup,
  required SourcePosition position,
  required T value,
  ConsistencyGroup? consistencyGroup,
}) {
  return ResourceSnapshot<T>(
    fieldGroup: fieldGroup,
    epoch: position.epoch,
    version: position.version,
    value: value,
    consistencyGroup: consistencyGroup,
  );
}

ConsistencyGroup _consistencyGroup(
  String id,
  SourcePosition position,
  Iterable<ChangedFieldGroup> changed,
) {
  return ConsistencyGroup(
    id: ConsistencyGroupId(id),
    position: position,
    changed: changed,
  );
}

void main() {
  test('runtime exposes an official ProviderListenable entry', () {
    final key = ResourceKey(
      scope: const ResourceScope('synthetic'),
      stableKey: 'message-1',
    );
    final fieldGroup = ResourceFieldGroup<String>(resource: key, name: 'body');
    final snapshot = ResourceSnapshot<String>(
      fieldGroup: fieldGroup,
      epoch: const SourceEpoch('epoch-a'),
      version: const SourceVersion(1),
      value: 'synthetic',
    );
    final entry = _Entry(fieldGroup, snapshot);

    expect(entry.resource, fieldGroup);
    expect(
      entry.listenable,
      isA<ProviderListenable<AsyncValue<ResourceSnapshot<String>>>>(),
    );
  });

  test('providers share one source observation inside a container', () async {
    final fieldGroup = ResourceFieldGroup<String>(
      resource: ResourceKey(
        scope: const ResourceScope('test'),
        stableKey: 'message',
      ),
      name: 'body',
    );
    final initialPosition = const SourcePosition(
      epoch: SourceEpoch('epoch-a'),
      version: SourceVersion(1),
    );
    final source = _TestSource<String>(
      fieldGroup: fieldGroup,
      initial: _snapshot(
        fieldGroup: fieldGroup,
        position: initialPosition,
        value: 'one',
      ),
    );
    final firstProvider = presentationResourceProvider(source);
    final secondProvider = presentationResourceProvider(source);
    final firstValues = <String>[];
    final secondValues = <String>[];
    final container = ProviderContainer.test();
    final firstSubscription = container.listen(
      firstProvider,
      (_, next) => next.asData?.value.value.let(firstValues.add),
      fireImmediately: true,
    );
    final secondSubscription = container.listen(
      secondProvider,
      (_, next) => next.asData?.value.value.let(secondValues.add),
      fireImmediately: true,
    );

    await _settle();

    expect(source.openCount, 1);
    expect(firstValues, <String>['one']);
    expect(secondValues, <String>['one']);

    firstSubscription.close();
    secondSubscription.close();
    await _settle();
    await source.close();
  });

  test('provider containers isolate observations and caches', () async {
    final fieldGroup = ResourceFieldGroup<String>(
      resource: ResourceKey(
        scope: const ResourceScope('test'),
        stableKey: 'isolated',
      ),
      name: 'body',
    );
    final source = _TestSource<String>(
      fieldGroup: fieldGroup,
      initial: _snapshot(
        fieldGroup: fieldGroup,
        position: const SourcePosition(
          epoch: SourceEpoch('epoch-a'),
          version: SourceVersion(1),
        ),
        value: 'isolated',
      ),
    );
    final provider = presentationResourceProvider(source);
    final first = ProviderContainer.test();
    final second = ProviderContainer.test();
    final firstSubscription = first.listen(provider, (_, __) {});
    final secondSubscription = second.listen(provider, (_, __) {});

    await _settle();

    expect(source.openCount, 2);
    firstSubscription.close();
    secondSubscription.close();
    await _settle();
    await source.close();
  });

  test('version admission rejects stale and different-epoch changes', () async {
    final fieldGroup = ResourceFieldGroup<String>(
      resource: ResourceKey(
        scope: const ResourceScope('test'),
        stableKey: 'versioned',
      ),
      name: 'body',
    );
    const epochA = SourceEpoch('epoch-a');
    const position1 = SourcePosition(epoch: epochA, version: SourceVersion(1));
    const position2 = SourcePosition(epoch: epochA, version: SourceVersion(2));
    const position3 = SourcePosition(epoch: epochA, version: SourceVersion(3));
    final source = _TestSource<String>(
      fieldGroup: fieldGroup,
      initial: _snapshot(
        fieldGroup: fieldGroup,
        position: position1,
        value: 'one',
      ),
    );
    final values = <String>[];
    final container = ProviderContainer.test();
    final subscription = container.listen(
      presentationResourceProvider(source),
      (_, next) => next.asData?.value.value.let(values.add),
    );
    await _settle();

    final group3 = _consistencyGroup('group-3', position3, <ChangedFieldGroup>[
      ChangedFieldGroup.of(fieldGroup),
    ]);
    source.emit(
      SourceChange<String>(
        snapshot: _snapshot(
          fieldGroup: fieldGroup,
          position: position3,
          value: 'three',
          consistencyGroup: group3,
        ),
        base: position1,
        group: group3,
      ),
    );
    await _settle();

    final group2 = _consistencyGroup('group-2', position2, <ChangedFieldGroup>[
      ChangedFieldGroup.of(fieldGroup),
    ]);
    source.emit(
      SourceChange<String>(
        snapshot: _snapshot(
          fieldGroup: fieldGroup,
          position: position2,
          value: 'two',
          consistencyGroup: group2,
        ),
        base: position1,
        group: group2,
      ),
    );
    source.emit(
      SourceChange<String>(
        snapshot: _snapshot(
          fieldGroup: fieldGroup,
          position: const SourcePosition(
            epoch: SourceEpoch('epoch-b'),
            version: SourceVersion(1),
          ),
          value: 'other-epoch',
          consistencyGroup: _consistencyGroup(
            'other-epoch',
            const SourcePosition(
              epoch: SourceEpoch('epoch-b'),
              version: SourceVersion(1),
            ),
            <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
          ),
        ),
        base: position3,
        group: _consistencyGroup(
          'other-epoch',
          const SourcePosition(
            epoch: SourceEpoch('epoch-b'),
            version: SourceVersion(1),
          ),
          <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
        ),
      ),
    );
    await _settle();

    expect(values, <String>['one', 'three']);
    expect(
      container.read(presentationRuntimeProvider).current(fieldGroup)?.value,
      'three',
    );
    subscription.close();
    await _settle();
    await source.close();
  });

  test('a consistency group installs its active members together', () async {
    final x = ResourceFieldGroup<String>(
      resource: ResourceKey(scope: const ResourceScope('test'), stableKey: 'x'),
      name: 'value',
    );
    final y = ResourceFieldGroup<String>(
      resource: ResourceKey(scope: const ResourceScope('test'), stableKey: 'y'),
      name: 'value',
    );
    const position1 = SourcePosition(
      epoch: SourceEpoch('epoch-a'),
      version: SourceVersion(1),
    );
    const position2 = SourcePosition(
      epoch: SourceEpoch('epoch-a'),
      version: SourceVersion(2),
    );
    final sourceX = _TestSource<String>(
      fieldGroup: x,
      initial: _snapshot(fieldGroup: x, position: position1, value: 'x1'),
    );
    final sourceY = _TestSource<String>(
      fieldGroup: y,
      initial: _snapshot(fieldGroup: y, position: position1, value: 'y1'),
    );
    final group = _consistencyGroup('xy-2', position2, <ChangedFieldGroup>[
      ChangedFieldGroup.of(x),
      ChangedFieldGroup.of(y),
    ]);
    final xValues = <String>[];
    final yValues = <String>[];
    final container = ProviderContainer.test();
    final xSubscription = container.listen(
      presentationResourceProvider(sourceX),
      (_, next) => next.asData?.value.value.let(xValues.add),
    );
    final ySubscription = container.listen(
      presentationResourceProvider(sourceY),
      (_, next) => next.asData?.value.value.let(yValues.add),
    );
    await _settle();

    sourceX.emit(
      SourceChange<String>(
        snapshot: _snapshot(
          fieldGroup: x,
          position: position2,
          value: 'x2',
          consistencyGroup: group,
        ),
        base: position1,
        group: group,
      ),
    );
    await _settle();
    expect(xValues, <String>['x1']);
    expect(yValues, <String>['y1']);

    sourceY.emit(
      SourceChange<String>(
        snapshot: _snapshot(
          fieldGroup: y,
          position: position2,
          value: 'y2',
          consistencyGroup: group,
        ),
        base: position1,
        group: group,
      ),
    );
    await _settle();
    expect(xValues, <String>['x1', 'x2']);
    expect(yValues, <String>['y1', 'y2']);

    xSubscription.close();
    ySubscription.close();
    await _settle();
    await sourceX.close();
    await sourceY.close();
  });

  test('runtime disposal releases source observation subscriptions', () async {
    final fieldGroup = ResourceFieldGroup<String>(
      resource: ResourceKey(
        scope: const ResourceScope('test'),
        stableKey: 'dispose',
      ),
      name: 'body',
    );
    final source = _TestSource<String>(
      fieldGroup: fieldGroup,
      initial: _snapshot(
        fieldGroup: fieldGroup,
        position: const SourcePosition(
          epoch: SourceEpoch('epoch-a'),
          version: SourceVersion(1),
        ),
        value: 'value',
      ),
    );
    final container = ProviderContainer.test();
    final subscription = container.listen(
      presentationResourceProvider(source),
      (_, __) {},
    );
    await _settle();
    subscription.close();
    await _settle();

    expect(source.cancelCount, 1);
    await source.close();
  });

  test('preparation invalidation protects a late result', () async {
    final fieldGroup = ResourceFieldGroup<String>(
      resource: ResourceKey(
        scope: const ResourceScope('test'),
        stableKey: 'prepare',
      ),
      name: 'body',
    );
    const position1 = SourcePosition(
      epoch: SourceEpoch('epoch-a'),
      version: SourceVersion(1),
    );
    const position2 = SourcePosition(
      epoch: SourceEpoch('epoch-a'),
      version: SourceVersion(2),
    );
    final runtime = PresentationRuntime(
      executor: BoundedPreparationExecutor(maxInFlightBytes: 64),
      cache: ByteLruCache<VersionedCacheKey, Object?>(capacityBytes: 64),
    );
    final completion = Completer<String>();
    final future = runtime.preparation.prepare<String>(
      snapshot: _snapshot(
        fieldGroup: fieldGroup,
        position: position1,
        value: 'source',
      ),
      generation: const RequestGeneration(1),
      estimatedBytes: 4,
      operation: () => completion.future,
    );
    runtime.preparation.invalidate(fieldGroup, source: position2);
    completion.complete('prepared');
    final result = await future;

    expect(runtime.preparation.canInstall(result), isFalse);
    runtime.dispose();
  });

  test(
    'preparation rejects results after source rebuild, switch, revocation, and runtime disposal',
    () async {
      final fieldGroup = ResourceFieldGroup<String>(
        resource: ResourceKey(
          scope: const ResourceScope('test'),
          stableKey: 'reject-cases',
        ),
        name: 'body',
      );
      final runtime = PresentationRuntime(
        executor: BoundedPreparationExecutor(maxInFlightBytes: 64),
        cache: ByteLruCache<VersionedCacheKey, Object?>(capacityBytes: 64),
      );
      final installer = PreparedResourceInstaller<String>(runtime.preparation);

      // 1. Source rebuild: epoch changes
      final rebuildCompleter = Completer<String>();
      final rebuildFuture = runtime.preparation.prepare<String>(
        snapshot: _snapshot(
          fieldGroup: fieldGroup,
          position: const SourcePosition(
            epoch: SourceEpoch('epoch-a'),
            version: SourceVersion(1),
          ),
          value: 'epoch-a-source',
        ),
        generation: const RequestGeneration(1),
        estimatedBytes: 4,
        operation: () => rebuildCompleter.future,
      );
      // Source rebuilds with new epoch
      runtime.preparation.prepare<String>(
        snapshot: _snapshot(
          fieldGroup: fieldGroup,
          position: const SourcePosition(
            epoch: SourceEpoch('epoch-b'),
            version: SourceVersion(1),
          ),
          value: 'epoch-b-source',
        ),
        generation: const RequestGeneration(2),
        estimatedBytes: 4,
        operation: () => 'epoch-b-prepared',
      );
      rebuildCompleter.complete('epoch-a-prepared');
      final rebuildResult = await rebuildFuture;
      expect(runtime.preparation.canInstall(rebuildResult), isFalse);
      final rebuildAcceptance = runtime.preparation.acceptanceFor(
        rebuildResult.request,
      );
      expect(rebuildAcceptance.isActive, isFalse);
      expect(installer.install(rebuildResult, rebuildAcceptance), isFalse);

      // 2. Source switch: position advances
      final switchCompleter = Completer<String>();
      final switchFuture = runtime.preparation.prepare<String>(
        snapshot: _snapshot(
          fieldGroup: fieldGroup,
          position: const SourcePosition(
            epoch: SourceEpoch('epoch-b'),
            version: SourceVersion(2),
          ),
          value: 'v2-source',
        ),
        generation: const RequestGeneration(3),
        estimatedBytes: 4,
        operation: () => switchCompleter.future,
      );
      runtime.preparation.invalidate(
        fieldGroup,
        source: const SourcePosition(
          epoch: SourceEpoch('epoch-b'),
          version: SourceVersion(3),
        ),
      );
      switchCompleter.complete('v2-prepared');
      final switchResult = await switchFuture;
      expect(runtime.preparation.canInstall(switchResult), isFalse);
      final switchAcceptance = runtime.preparation.acceptanceFor(
        switchResult.request,
      );
      expect(switchAcceptance.isActive, isFalse);
      expect(installer.install(switchResult, switchAcceptance), isFalse);

      // 3. Revocation: explicit invalidate
      final revokeCompleter = Completer<String>();
      final revokeFuture = runtime.preparation.prepare<String>(
        snapshot: _snapshot(
          fieldGroup: fieldGroup,
          position: const SourcePosition(
            epoch: SourceEpoch('epoch-b'),
            version: SourceVersion(4),
          ),
          value: 'v4-source',
        ),
        generation: const RequestGeneration(4),
        estimatedBytes: 4,
        operation: () => revokeCompleter.future,
      );
      runtime.preparation.invalidate(fieldGroup);
      revokeCompleter.complete('v4-prepared');
      final revokeResult = await revokeFuture;
      expect(runtime.preparation.canInstall(revokeResult), isFalse);
      final revokeAcceptance = runtime.preparation.acceptanceFor(
        revokeResult.request,
      );
      expect(revokeAcceptance.status, PreparationStatus.revoked);
      expect(installer.install(revokeResult, revokeAcceptance), isFalse);

      // 4. Disposal: runtime disposed
      final disposeResult = PreparedResource<String>(
        request: PreparationRequest<String>.fromSnapshot(
          snapshot: _snapshot(
            fieldGroup: fieldGroup,
            position: const SourcePosition(
              epoch: SourceEpoch('epoch-b'),
              version: SourceVersion(5),
            ),
            value: 'v5-source',
          ),
          generation: const RequestGeneration(5),
        ),
        value: 'v5-prepared',
      );
      runtime.dispose();
      expect(runtime.preparation.canInstall(disposeResult), isFalse);
      final disposeAcceptance = runtime.preparation.acceptanceFor(
        disposeResult.request,
      );
      expect(disposeAcceptance.status, PreparationStatus.disposed);
      expect(installer.install(disposeResult, disposeAcceptance), isFalse);
    },
  );

  test('executor gives background work a fair batch turn', () async {
    final executor = BoundedPreparationExecutor(
      maxWorkers: 1,
      batchSize: 2,
      maxPendingTasks: 8,
      maxQueuedBytes: 64,
      maxInFlightBytes: 64,
    );
    final first = Completer<void>();
    final order = <String>[];
    executor.submit<void>(() async {
      order.add('foreground-1');
      await first.future;
    });
    executor.submit<void>(() => order.add('foreground-2'));
    executor.submit<void>(() => order.add('foreground-3'));
    executor.submit<void>(
      () => order.add('background'),
      priority: PreparationPriority.background,
    );
    first.complete();
    await executor.idle;

    expect(order, <String>[
      'foreground-1',
      'foreground-2',
      'background',
      'foreground-3',
    ]);
    executor.dispose();
  });

  test('executor rejects work when task or byte capacity is full', () async {
    final executor = BoundedPreparationExecutor(
      maxWorkers: 1,
      maxPendingTasks: 2,
      maxQueuedBytes: 4,
      maxInFlightBytes: 4,
    );
    final first = Completer<void>();
    executor.submit<void>(() => first.future, estimatedBytes: 2);
    executor.submit<void>(() {}, estimatedBytes: 2);
    final rejected = executor.submit<void>(() {}, estimatedBytes: 1);

    await expectLater(
      rejected,
      throwsA(isA<PreparationBackpressureException>()),
    );
    first.complete();
    await executor.idle;
    executor.dispose();
  });

  test('byte cache retains referenced values during eviction', () {
    final cache = ByteLruCache<String, String>(capacityBytes: 5);
    cache.put('a', 'A', bytes: 3);
    cache.put('b', 'B', bytes: 2);
    expect(cache.get('a'), 'A');
    cache.put('c', 'C', bytes: 2);
    expect(cache.containsKey('b'), isFalse);

    final lease = cache.retain('a')!;
    final rejected = cache.put('d', 'D', bytes: 3);
    expect(rejected.status, ByteCachePutStatus.rejected);
    expect(cache.residentBytes, 5);
    expect(cache.referencedBytes, 3);

    lease.release();
    expect(cache.put('d', 'D', bytes: 3).stored, isTrue);
    expect(cache.residentBytes, lessThanOrEqualTo(5));
  });

  test('moved markdown parser remains pure and renderer independent', () {
    final parsed = parseMessageMarkdownBlocks('# Heading\n\nbody');

    expect(parsed, hasLength(2));
    expect(parsed.first.type, MessageMarkdownBlockType.heading);
    expect(parsed.last.type, MessageMarkdownBlockType.paragraph);
  });
}

extension<T> on T? {
  void let(void Function(T value) callback) {
    final value = this;
    if (value != null) callback(value);
  }
}
