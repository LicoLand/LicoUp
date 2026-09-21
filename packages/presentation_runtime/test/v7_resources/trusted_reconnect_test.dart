import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:test/test.dart';

import 'source_support.dart';

void main() {
  late ResourceFieldGroup<String> body;
  late ResourceFieldGroup<String> prepared;
  late ResourceFieldGroup<String> lateCopy;
  late TestIncarnation<String> incarnation;
  late TestSource<String> source;
  late PresentationRuntime runtime;
  late List<SourceInvalidation> invalidations;

  setUp(() {
    body = ResourceFieldGroup<String>(
      resource: testResource('message'),
      name: 'body',
    );
    prepared = ResourceFieldGroup<String>(
      resource: testResource('message'),
      name: 'body.prepared',
    );
    lateCopy = ResourceFieldGroup<String>(
      resource: testResource('message'),
      name: 'body.prepared.copy',
    );
    incarnation = TestIncarnation<String>(
      testSnapshot<String>(
        fieldGroup: body,
        position: testPosition('epoch-a', 3),
        value: 'three',
      ),
    );
    source = TestSource<String>(fieldGroup: body, incarnation: incarnation);
    runtime = PresentationRuntime();
    invalidations = <SourceInvalidation>[];
    runtime.onSourceInvalidated(invalidations.add);
  });

  tearDown(() {
    runtime.dispose();
  });

  test(
    'an ended source needs an explicit reconnect, then admits again',
    () async {
      final ownership = runtime.own(source);
      await settle();
      expect(ownership.isOpen, isTrue);
      expect(ownership.current?.value, 'three');

      await incarnation.end();
      await settle();
      expect(ownership.isDisconnected, isTrue);
      expect(
        ownership.current?.value,
        'three',
        reason: 'a disconnect is not a revocation: nothing was withdrawn',
      );
      expect(
        source.openCount,
        1,
        reason: 'nothing is retried on a widget\'s behalf',
      );

      final next = await source.reconnectWith(
        value: 'four',
        position: testPosition('epoch-a', 4),
      );
      await ownership.reconnect();
      expect(ownership.isOpen, isTrue);
      expect(ownership.current?.value, 'four');
      expect(source.openCount, 2);
      expect(invalidations, isEmpty, reason: 'the same epoch was kept');

      final group = testGroup(
        id: 'group-5',
        position: testPosition('epoch-a', 5),
        changed: <ResourceFieldGroup<Object?>>[body],
      );
      next.emit(
        testChange<String>(
          snapshot: testSnapshot<String>(
            fieldGroup: body,
            position: testPosition('epoch-a', 5),
            value: 'five',
            group: group,
          ),
          base: testPosition('epoch-a', 4),
          group: group,
        ),
      );
      await settle();
      expect(ownership.current?.value, 'five');
    },
  );

  test('a reconnect never rolls the value back inside one epoch', () async {
    final ownership = runtime.own(source);
    await settle();
    expect(ownership.current?.value, 'three');

    incarnation.publish('two', testPosition('epoch-a', 2));
    await ownership.reconnect();
    expect(
      ownership.current?.value,
      'three',
      reason: 'an older value from the same incarnation is not a new value',
    );

    incarnation.publish('three', testPosition('epoch-a', 3));
    await ownership.reconnect();
    expect(ownership.current?.value, 'three');

    incarnation.publish('four', testPosition('epoch-a', 4));
    await ownership.reconnect();
    expect(ownership.current?.value, 'four');
    expect(invalidations, isEmpty);
  });

  test('a recompute reads the source again without rolling it back', () async {
    final ownership = runtime.own(source);
    await settle();
    expect(source.openCount, 1);

    runtime.recompute();
    await settle();
    expect(source.openCount, 2);
    expect(
      ownership.current?.value,
      'three',
      reason: 'a repeated read of the same position is not a new value',
    );

    incarnation.publish('four', testPosition('epoch-a', 4));
    runtime.recompute();
    await settle();
    expect(ownership.current?.value, 'four');
    expect(ownership.isOpen, isTrue);
  });

  test(
    'a replaced incarnation invalidates what the old one prepared',
    () async {
      final display = runtime.preparedDisplay<String>();
      final ownership = runtime.own(source);
      await settle();

      final preparedSnapshot = testSnapshot<String>(
        fieldGroup: prepared,
        position: testPosition('epoch-a', 3),
        value: 'prepared-three',
      );
      expect(
        await display.prepareAndOffer(
          snapshot: preparedSnapshot,
          generation: const RequestGeneration(1),
          operation: () => preparedSnapshot.value,
          estimatedBytes: 4,
        ),
        GroupInstallOutcome.installed,
      );
      expect(display.current(prepared)?.value, 'prepared-three');

      // A late attempt over the incarnation that is about to disappear. Another
      // prepared field group is used so the value is not already cached and the
      // attempt is genuinely in flight.
      final late = Completer<String>();
      final lateOffer = display.prepareAndOffer(
        snapshot: testSnapshot<String>(
          fieldGroup: lateCopy,
          position: testPosition('epoch-a', 3),
          value: 'prepared-late',
        ),
        generation: const RequestGeneration(2),
        operation: () => late.future,
        estimatedBytes: 4,
      );

      await source.reconnectWith(
        value: 'one-of-epoch-b',
        position: testPosition('epoch-b', 1),
      );
      await ownership.reconnect();
      await settle();

      expect(ownership.current?.value, 'one-of-epoch-b');
      expect(
        display.current(prepared),
        isNull,
        reason: 'values prepared from the replaced epoch stop being visible',
      );
      expect(display.trackedGroups, 0);
      expect(
        invalidations.map((event) => event.reason),
        <SourceInvalidationReason>[SourceInvalidationReason.epochReplaced],
      );
      expect(invalidations.single.replacedEpoch, const SourceEpoch('epoch-a'));
      expect(invalidations.single.position, testPosition('epoch-b', 1));

      late.complete('prepared-late');
      expect(
        await lateOffer,
        GroupInstallOutcome.rejected,
        reason: 'work that finished after the replacement cannot install',
      );
      expect(display.installed, isEmpty);

      // The new incarnation installs normally.
      final fresh = testSnapshot<String>(
        fieldGroup: prepared,
        position: testPosition('epoch-b', 1),
        value: 'prepared-of-epoch-b',
      );
      expect(
        await display.prepareAndOffer(
          snapshot: fresh,
          generation: const RequestGeneration(3),
          operation: () => fresh.value,
          estimatedBytes: 4,
        ),
        GroupInstallOutcome.installed,
      );
      expect(display.current(prepared)?.value, 'prepared-of-epoch-b');
    },
  );

  test('a withdrawn resource refuses the revoked lineage', () async {
    final ownership = runtime.own(source);
    await settle();
    final group = testGroup(
      id: 'group-4',
      position: testPosition('epoch-a', 4),
      changed: <ResourceFieldGroup<Object?>>[body],
    );
    incarnation.emit(
      testChange<String>(
        snapshot: testSnapshot<String>(
          fieldGroup: body,
          position: testPosition('epoch-a', 4),
          value: 'four',
          group: group,
        ),
        base: testPosition('epoch-a', 3),
        group: group,
      ),
    );
    await settle();
    expect(ownership.current?.value, 'four');

    runtime.revoke(body.resource);
    expect(ownership.current, isNull);
    expect(runtime.current(body), isNull);
    expect(invalidations, hasLength(1));
    expect(invalidations.single.reason, SourceInvalidationReason.revoked);

    // A change built on the withdrawn position cannot bring the lineage back.
    incarnation.emit(
      testChange<String>(
        snapshot: testSnapshot<String>(
          fieldGroup: body,
          position: testPosition('epoch-a', 5),
          value: 'five',
          group: testGroup(
            id: 'group-5',
            position: testPosition('epoch-a', 5),
            changed: <ResourceFieldGroup<Object?>>[body],
          ),
        ),
        base: testPosition('epoch-a', 4),
        group: testGroup(
          id: 'group-5',
          position: testPosition('epoch-a', 5),
          changed: <ResourceFieldGroup<Object?>>[body],
        ),
      ),
    );
    await settle();
    expect(ownership.current, isNull);

    // A fresh read is admitted: the application still owns the session.
    incarnation.publish('six', testPosition('epoch-a', 6));
    await ownership.reconnect();
    expect(ownership.current?.value, 'six');
  });
}
