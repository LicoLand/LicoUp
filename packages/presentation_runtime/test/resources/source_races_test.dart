import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'source_support.dart';

final class DeferredSource implements PresentationSource<String> {
  DeferredSource(this.fieldGroup);
  @override
  final ResourceFieldGroup<String> fieldGroup;
  final reads = <Completer<SourceObservation<String>>>[];

  @override
  Future<SourceObservation<String>> open() {
    final read = Completer<SourceObservation<String>>();
    reads.add(read);
    return read.future;
  }

  void finish(int index, String epoch) {
    reads[index].complete(
      SourceObservation(
        initial: testSnapshot(
          fieldGroup: fieldGroup,
          position: testPosition(epoch, 1),
          value: epoch,
        ),
        changes: const Stream.empty(),
      ),
    );
  }
}

void main() {
  final body = ResourceFieldGroup<String>(
    resource: testResource('a'),
    name: 'body',
  );
  final metadata = ResourceFieldGroup<String>(
    resource: testResource('b'),
    name: 'metadata',
  );

  test('each lease releases once without releasing another owner', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final incarnation = TestIncarnation(
      testSnapshot(
        fieldGroup: body,
        position: testPosition('a', 1),
        value: 'one',
      ),
    );
    final source = TestSource(fieldGroup: body, incarnation: incarnation);
    final first = runtime.own(source);
    final second = runtime.own(source);
    await settle();
    await first.release();
    await first.release();
    expect(second.isOpen, isTrue);
    expect(source.cancelCount, 0);
    await second.release();
    expect(source.cancelCount, 1);
  });

  test(
    'stale open completion cannot clear or replace a newer pending read',
    () async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final source = DeferredSource(body);
      final owner = runtime.own(source);
      final reconnect = owner.reconnect();
      expect(source.reads, hasLength(2));
      source.finish(0, 'old');
      await settle();
      final another = runtime.own(source);
      expect(source.reads, hasLength(2));
      source.finish(1, 'new');
      await reconnect;
      expect(owner.current?.value, 'new');
      await another.release();
    },
  );

  test('revocation fences pending initial reads and queued replay', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final source = DeferredSource(body);
    final owner = runtime.own(source);
    runtime.revoke(body.resource);
    source.finish(0, 'revoked');
    await settle();
    expect(runtime.current(body), isNull);
    expect(source.reads, hasLength(1));
    final fresh = owner.reconnect();
    source.finish(1, 'fresh');
    await fresh;
    final values = <String>[];
    final errors = <Object>[];
    final subscription = owner.subscribe();
    subscription.stream.listen(
      (value) => values.add(value.value),
      onError: errors.add,
    );
    runtime.revoke(body.resource);
    await settle();
    expect(values, isEmpty);
    expect(errors, hasLength(1));
  });

  test('a new subscriber does not reconnect a disconnected source', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final source = DeferredSource(body);
    final owner = runtime.own(source);
    source.finish(0, 'one');
    await settle();
    expect(owner.isDisconnected, isTrue);
    final subscription = owner.subscribe();
    subscription.stream.listen((_) {});
    await settle();
    expect(source.reads, hasLength(1));
  });

  test('chained group updates merge losslessly while siblings lag', () async {
    final merged = <String>[];
    final store = ResourceObservationStore(
      onSnapshot: (snapshot) {
        merged.add((snapshot as ResourceSnapshot<String>).value);
      },
    );
    addTearDown(store.dispose);
    final a = TestIncarnation(
      testSnapshot(
        fieldGroup: body,
        position: testPosition('a', 1),
        value: 'a1',
      ),
    );
    final b = TestIncarnation(
      testSnapshot(
        fieldGroup: metadata,
        position: testPosition('a', 1),
        value: 'b1',
      ),
    );
    store.own(TestSource(fieldGroup: body, incarnation: a));
    store.own(TestSource(fieldGroup: metadata, incarnation: b));
    await settle();
    merged.clear();
    void emit(TestIncarnation<String> source, int version, String value) {
      final group = testGroup(
        id: 'group-$version',
        position: testPosition('a', version),
        changed: [body, metadata],
      );
      source.emit(
        testChange(
          snapshot: testSnapshot(
            fieldGroup: source.fieldGroup,
            position: group.position,
            value: value,
            group: group,
          ),
          base: testPosition('a', version - 1),
          group: group,
        ),
      );
    }

    emit(a, 2, 'a2');
    emit(a, 3, 'a3');
    expect(store.current(body)?.value, 'a1');
    emit(b, 2, 'b2');
    expect(store.current(body)?.value, 'a2');
    emit(b, 3, 'b3');
    expect(store.current(body)?.value, 'a3');
    expect(store.current(metadata)?.value, 'b3');
    expect(merged, ['a2', 'b2', 'a3', 'b3']);
  });

  test(
    'a resume delivers once to a subscriber that arrived while paused',
    () async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final incarnation = TestIncarnation(
        testSnapshot(
          fieldGroup: body,
          position: testPosition('a', 1),
          value: 'one',
        ),
      );
      final source = TestSource(fieldGroup: body, incarnation: incarnation);
      runtime.own(source);
      final first = <String>[];
      final firstSubscription = runtime.observe(source);
      firstSubscription.stream.listen((value) => first.add(value.value));
      await settle();
      expect(first, ['one']);

      runtime.pause();
      final late = <String>[];
      final lateSubscription = runtime.observe(source);
      lateSubscription.stream.listen((value) => late.add(value.value));
      final group = testGroup(
        id: 'group-2',
        position: testPosition('a', 2),
        changed: <ResourceFieldGroup<Object?>>[body],
      );
      incarnation.emit(
        testChange(
          snapshot: testSnapshot(
            fieldGroup: body,
            position: testPosition('a', 2),
            value: 'two',
            group: group,
          ),
          base: testPosition('a', 1),
          group: group,
        ),
      );
      await settle();
      expect(first, ['one'], reason: 'presentation delivery is paused');
      expect(late, isEmpty);

      runtime.resume();
      await settle();
      expect(first, ['one', 'two']);
      expect(late, [
        'two',
      ], reason: 'the late subscriber gets the merged value');
      await firstSubscription.close();
      await lateSubscription.close();
    },
  );

  test(
    'a re-read of an admitted group position cannot dissolve the group',
    () async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final incarnation = TestIncarnation(
        testSnapshot(
          fieldGroup: body,
          position: testPosition('a', 1),
          value: 'a1',
        ),
      );
      final source = TestSource(fieldGroup: body, incarnation: incarnation);
      final metadataIncarnation = TestIncarnation(
        testSnapshot(
          fieldGroup: metadata,
          position: testPosition('a', 1),
          value: 'b1',
        ),
      );
      final ownership = runtime.own(source);
      runtime.own(
        TestSource(fieldGroup: metadata, incarnation: metadataIncarnation),
      );
      await settle();

      final group = testGroup(
        id: 'group-2',
        position: testPosition('a', 2),
        changed: <ResourceFieldGroup<Object?>>[body, metadata],
      );
      incarnation.emit(
        testChange(
          snapshot: testSnapshot(
            fieldGroup: body,
            position: testPosition('a', 2),
            value: 'a2',
            group: group,
          ),
          base: testPosition('a', 1),
          group: group,
        ),
      );
      await settle();
      expect(runtime.current(body)?.value, 'a1');

      // The source reconnects and repeats the position the staged group owns. It
      // is not a new value, and installing it without the group would mix it with
      // the sibling's older version.
      incarnation.publish('a2', testPosition('a', 2));
      await ownership.reconnect();
      expect(runtime.current(body)?.value, 'a1');

      metadataIncarnation.emit(
        testChange(
          snapshot: testSnapshot(
            fieldGroup: metadata,
            position: testPosition('a', 2),
            value: 'b2',
            group: group,
          ),
          base: testPosition('a', 1),
          group: group,
        ),
      );
      await settle();
      expect(runtime.current(body)?.value, 'a2');
      expect(runtime.current(metadata)?.value, 'b2');
    },
  );

  test(
    'an epoch replacement drops a group staged from the replaced epoch',
    () async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final invalidations = <SourceInvalidation>[];
      runtime.onSourceInvalidated(invalidations.add);
      final incarnation = TestIncarnation(
        testSnapshot(
          fieldGroup: body,
          position: testPosition('a', 1),
          value: 'a1',
        ),
      );
      final source = TestSource(fieldGroup: body, incarnation: incarnation);
      final metadataIncarnation = TestIncarnation(
        testSnapshot(
          fieldGroup: metadata,
          position: testPosition('a', 1),
          value: 'b1',
        ),
      );
      final metadataSource = TestSource(
        fieldGroup: metadata,
        incarnation: metadataIncarnation,
      );
      final ownership = runtime.own(source);
      final metadataOwnership = runtime.own(metadataSource);
      await settle();

      final oldGroup = testGroup(
        id: 'group-2',
        position: testPosition('a', 2),
        changed: <ResourceFieldGroup<Object?>>[body, metadata],
      );
      incarnation.emit(
        testChange(
          snapshot: testSnapshot(
            fieldGroup: body,
            position: testPosition('a', 2),
            value: 'a2',
            group: oldGroup,
          ),
          base: testPosition('a', 1),
          group: oldGroup,
        ),
      );
      await settle();
      expect(runtime.current(body)?.value, 'a1');

      // The source reconnects into a new incarnation before the group completed.
      await source.reconnectWith(
        value: 'new-epoch',
        position: testPosition('b', 1),
      );
      await ownership.reconnect();
      await settle();
      expect(runtime.current(body)?.value, 'new-epoch');
      expect(
        invalidations.map((event) => event.reason),
        contains(SourceInvalidationReason.epochReplaced),
      );

      // The old epoch's sibling arriving late cannot complete the dropped group.
      metadataIncarnation.emit(
        testChange(
          snapshot: testSnapshot(
            fieldGroup: metadata,
            position: testPosition('a', 2),
            value: 'b2',
            group: oldGroup,
          ),
          base: testPosition('a', 1),
          group: oldGroup,
        ),
      );
      await settle();
      expect(runtime.current(body)?.value, 'new-epoch');
      expect(
        runtime.current(metadata)?.value,
        'b1',
        reason: 'a member of the replaced epoch cannot install beside it',
      );

      // The sibling's own source follows into the new incarnation, and a group of
      // that incarnation installs normally.
      await metadataSource.reconnectWith(
        value: 'b-new-epoch',
        position: testPosition('b', 1),
      );
      await metadataOwnership.reconnect();
      await settle();
      expect(runtime.current(metadata)?.value, 'b-new-epoch');

      final newGroup = testGroup(
        id: 'group-b2',
        position: testPosition('b', 2),
        changed: <ResourceFieldGroup<Object?>>[body, metadata],
      );
      source.served.emit(
        testChange(
          snapshot: testSnapshot(
            fieldGroup: body,
            position: testPosition('b', 2),
            value: 'a2-new',
            group: newGroup,
          ),
          base: testPosition('b', 1),
          group: newGroup,
        ),
      );
      metadataSource.served.emit(
        testChange(
          snapshot: testSnapshot(
            fieldGroup: metadata,
            position: testPosition('b', 2),
            value: 'b2-new',
            group: newGroup,
          ),
          base: testPosition('b', 1),
          group: newGroup,
        ),
      );
      await settle();
      expect(runtime.current(body)?.value, 'a2-new');
      expect(runtime.current(metadata)?.value, 'b2-new');
    },
  );

  test('revocation reports exactly the visible value it withdraws', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final source = DeferredSource(body);
    final owner = runtime.own(source);
    final errors = <Object>[];
    final subscription = owner.subscribe();
    subscription.stream.listen((_) {}, onError: errors.add);
    runtime.revoke(body.resource);
    await settle();
    expect(
      errors,
      isEmpty,
      reason: 'nothing was visible, so nothing was withdrawn',
    );

    final fresh = owner.reconnect();
    source.finish(1, 'fresh');
    await fresh;
    await settle();
    runtime.revoke(body.resource);
    await settle();
    expect(errors, hasLength(1));
    expect(runtime.current(body), isNull);
  });

  test(
    'an inconsistent initial group is reported instead of dropped',
    () async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final group = testGroup(
        id: 'group-1',
        position: testPosition('a', 1),
        changed: <ResourceFieldGroup<Object?>>[metadata],
      );
      final incarnation = TestIncarnation(
        testSnapshot(
          fieldGroup: body,
          position: testPosition('a', 1),
          value: 'one',
          group: group,
        ),
      );
      final source = TestSource(fieldGroup: body, incarnation: incarnation);
      final errors = <Object>[];
      final subscription = runtime.observe(source);
      subscription.stream.listen((_) {}, onError: errors.add);
      await settle();
      expect(errors, hasLength(1));
      expect(runtime.current(body), isNull);
    },
  );

  test(
    'Riverpod receives invalidation instead of retaining revoked data',
    () async {
      final container = ProviderContainer.test();
      final runtime = container.read(presentationRuntimeProvider);
      final source = TestSource(
        fieldGroup: body,
        incarnation: TestIncarnation(
          testSnapshot(
            fieldGroup: body,
            position: testPosition('a', 1),
            value: 'private fixture',
          ),
        ),
      );
      runtime.own(source);
      final provider = presentationResourceProvider(source);
      container.listen(provider, (_, __) {});
      await settle();
      expect(container.read(provider).asData, isNotNull);
      runtime.revoke(body.resource);
      await settle();
      expect(container.read(provider).asData, isNull);
      expect(container.read(provider).hasError, isTrue);
    },
  );
}
