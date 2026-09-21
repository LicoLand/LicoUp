import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'source_support.dart';

void main() {
  late ResourceFieldGroup<String> body;
  late TestSource<String> source;
  late TestIncarnation<String> incarnation;
  late PresentationRuntime runtime;

  setUp(() {
    body = ResourceFieldGroup<String>(
      resource: testResource('message'),
      name: 'body',
    );
    incarnation = TestIncarnation<String>(
      testSnapshot<String>(
        fieldGroup: body,
        position: testPosition('epoch-a', 1),
        value: 'one',
      ),
    );
    source = TestSource<String>(fieldGroup: body, incarnation: incarnation);
    runtime = PresentationRuntime();
  });

  tearDown(() {
    runtime.dispose();
  });

  test('a widget subscription does not own the source binding', () async {
    final ownership = runtime.own(source);
    final firstValues = <String>[];
    final first = ownership.subscribe();
    first.stream.listen((snapshot) => firstValues.add(snapshot.value));
    await settle();

    expect(source.openCount, 1);
    expect(firstValues, <String>['one']);

    // The widget stops looking. An owned binding is not closed by that, and
    // nothing is read again.
    await first.close();
    await settle();
    expect(source.cancelCount, 0);
    expect(ownership.isOpen, isTrue);
    expect(ownership.current?.value, 'one');

    // A rebuild subscribes again: the admitted value is replayed, so no fetch
    // and no session reopen happens, and live updates still arrive.
    final secondValues = <String>[];
    final second = ownership.subscribe();
    second.stream.listen((snapshot) => secondValues.add(snapshot.value));
    await settle();
    expect(source.openCount, 1);
    expect(secondValues, <String>['one']);

    final group = testGroup(
      id: 'group-2',
      position: testPosition('epoch-a', 2),
      changed: <ResourceFieldGroup<Object?>>[body],
    );
    incarnation.emit(
      testChange<String>(
        snapshot: testSnapshot<String>(
          fieldGroup: body,
          position: testPosition('epoch-a', 2),
          value: 'two',
          group: group,
        ),
        base: testPosition('epoch-a', 1),
        group: group,
      ),
    );
    await settle();
    expect(secondValues, <String>['one', 'two']);
    expect(source.openCount, 1, reason: 'a rebuild never re-reads the source');

    // Only the application scope releases the binding.
    await second.close();
    await ownership.release();
    await settle();
    expect(source.cancelCount, 1);
    expect(ownership.isOpen, isFalse);
  });

  test('offscreen pause keeps merging without crossing the source', () async {
    final ownership = runtime.own(source);
    final values = <String>[];
    final subscription = ownership.subscribe();
    subscription.stream.listen((snapshot) => values.add(snapshot.value));
    await settle();

    runtime.pause();
    expect(ownership.isPaused, isTrue);
    expect(
      ownership.isOpen,
      isTrue,
      reason: 'an offscreen pause is a display decision, not a source one',
    );
    expect(source.cancelCount, 0);

    final group = testGroup(
      id: 'group-2',
      position: testPosition('epoch-a', 2),
      changed: <ResourceFieldGroup<Object?>>[body],
    );
    incarnation.emit(
      testChange<String>(
        snapshot: testSnapshot<String>(
          fieldGroup: body,
          position: testPosition('epoch-a', 2),
          value: 'two',
          group: group,
        ),
        base: testPosition('epoch-a', 1),
        group: group,
      ),
    );
    await settle();

    expect(
      ownership.current?.value,
      'two',
      reason: 'reliable source events are merged while nothing is displayed',
    );
    expect(values, <String>['one']);

    runtime.resume();
    await settle();
    expect(values, <String>['one', 'two']);
  });

  test(
    'the official Riverpod lifecycle keeps the binding in the container',
    () async {
      final container = ProviderContainer.test();
      final containerRuntime = container.read(presentationRuntimeProvider);
      final ownership = containerRuntime.own(source);
      final provider = presentationResourceProvider(source);
      final firstValues = <String>[];
      final first = container.listen(provider, (_, next) {
        final snapshot = next.asData?.value;
        if (snapshot != null) firstValues.add(snapshot.value);
      });
      await settle();

      expect(source.openCount, 1);
      expect(firstValues, <String>['one']);

      // The auto-disposed provider is torn down exactly as a widget that stops
      // watching does. The container-scoped application lease is untouched.
      first.close();
      await settle();
      expect(source.cancelCount, 0);
      expect(ownership.isOpen, isTrue);

      final secondValues = <String>[];
      final second = container.listen(provider, (_, next) {
        final snapshot = next.asData?.value;
        if (snapshot != null) secondValues.add(snapshot.value);
      });
      await settle();
      expect(source.openCount, 1, reason: 'the container kept the observation');
      expect(secondValues, <String>['one']);
      second.close();
    },
  );

  test('a source without an application lease is released by its last '
      'subscriber', () async {
    final subscription = runtime.observe(source);
    final values = <String>[];
    subscription.stream.listen((snapshot) => values.add(snapshot.value));
    await settle();
    expect(source.openCount, 1);
    expect(values, <String>['one']);

    await subscription.close();
    await settle();
    expect(source.cancelCount, 1);
    expect(
      runtime.current(body)?.value,
      'one',
      reason: 'the last read value stays with the container',
    );
  });
}
