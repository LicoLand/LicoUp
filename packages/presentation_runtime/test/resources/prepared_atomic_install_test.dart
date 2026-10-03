import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:test/test.dart';

import 'source_support.dart';

void main() {
  late ResourceFieldGroup<String> body;
  late ResourceFieldGroup<String> metadata;
  late ResourceFieldGroup<String> other;
  late PresentationRuntime runtime;
  late PreparedDisplay<String> display;
  late List<Map<ResourceFieldGroup<String>, PreparedResource<String>>>
  published;
  late List<Set<ResourceFieldGroup<String>>> withdrawn;

  setUp(() {
    body = ResourceFieldGroup<String>(
      resource: testResource('message'),
      name: 'body.prepared',
    );
    metadata = ResourceFieldGroup<String>(
      resource: testResource('message'),
      name: 'metadata.prepared',
    );
    other = ResourceFieldGroup<String>(
      resource: testResource('other'),
      name: 'body.prepared',
    );
    runtime = PresentationRuntime();
    display = runtime.preparedDisplay<String>();
    published = <Map<ResourceFieldGroup<String>, PreparedResource<String>>>[];
    withdrawn = <Set<ResourceFieldGroup<String>>>[];
    display.onInstalled(published.add);
    display.onWithdrawn(withdrawn.add);
  });

  tearDown(() {
    runtime.dispose();
  });

  ResourceSnapshot<String> preparedAt(
    ResourceFieldGroup<String> field,
    String value,
    SourcePosition position, {
    ConsistencyGroup? group,
  }) => testSnapshot<String>(
    fieldGroup: field,
    position: position,
    value: value,
    group: group,
  );

  Future<GroupInstallOutcome> offer(
    ResourceSnapshot<String> snapshot,
    int generation,
  ) => display.prepareAndOffer(
    snapshot: snapshot,
    generation: RequestGeneration(generation),
    operation: () => snapshot.value,
    estimatedBytes: 4,
  );

  test('a consistency group becomes visible in one step, and only its own '
      'loading waits', () async {
    const epochA = 'epoch-a';
    final position1 = testPosition(epochA, 1);
    final position2 = testPosition(epochA, 2);
    final group = testGroup(
      id: 'message-2',
      position: position2,
      changed: <ResourceFieldGroup<Object?>>[body, metadata],
    );

    expect(
      await offer(preparedAt(body, 'body-1', position1), 1),
      GroupInstallOutcome.installed,
    );

    final staged = await offer(
      preparedAt(body, 'body-2', position2, group: group),
      2,
    );
    expect(staged, GroupInstallOutcome.staged);
    expect(
      display.current(body)?.value,
      'body-1',
      reason: 'nothing from an incomplete group is visible',
    );
    expect(display.current(metadata), isNull);
    expect(
      display.gateFor(group)?.pending,
      hasLength(1),
      reason: 'the group reports exactly its own missing member',
    );

    // A group that is still loading does not delay anything else.
    expect(
      await offer(preparedAt(other, 'other-1', position1), 3),
      GroupInstallOutcome.installed,
    );
    expect(display.current(other)?.value, 'other-1');

    expect(
      await offer(
        preparedAt(metadata, 'metadata-2', position2, group: group),
        4,
      ),
      GroupInstallOutcome.installed,
    );
    expect(display.current(body)?.value, 'body-2');
    expect(display.current(metadata)?.value, 'metadata-2');
    expect(display.gateFor(group)?.isInstalled, isTrue);
    expect(
      published.last[body]?.request.consistencyGroup,
      group,
      reason: 'the group identity survives from the source read to the install',
    );
    expect(published.last[metadata]?.request.consistencyGroup, group);
    expect(published.last, hasLength(2), reason: 'one step per group install');
  });

  test(
    'revoking a resource withdraws the members that are already visible',
    () async {
      final position2 = testPosition('epoch-a', 2);
      final group = testGroup(
        id: 'message-2',
        position: position2,
        changed: <ResourceFieldGroup<Object?>>[body, metadata],
      );
      final bodyResult = preparedAt(body, 'body-2', position2, group: group);
      expect(await offer(bodyResult, 1), GroupInstallOutcome.staged);

      final late = Completer<String>();
      final lateOffer = display.prepareAndOffer(
        snapshot: preparedAt(metadata, 'metadata-2', position2, group: group),
        generation: const RequestGeneration(2),
        operation: () => late.future,
        estimatedBytes: 4,
      );
      late.complete('metadata-2');
      expect(await lateOffer, GroupInstallOutcome.installed);
      expect(display.current(body)?.value, 'body-2');
      expect(display.current(metadata)?.value, 'metadata-2');

      runtime.revoke(body.resource);

      expect(
        display.current(body),
        isNull,
        reason: 'authority loss takes the visible member away at once',
      );
      expect(display.current(metadata), isNull);
      expect(display.installed, isEmpty);
      expect(display.trackedGroups, 0);
      expect(withdrawn, <Set<ResourceFieldGroup<String>>>[
        <ResourceFieldGroup<String>>{body, metadata},
      ], reason: 'the whole group stops being visible in one step');

      // A result that finished before the revocation cannot install now.
      expect(
        display.offer(
          PreparedResource<String>(
            request: PreparationRequest<String>.fromSnapshot(
              snapshot: preparedAt(
                metadata,
                'metadata-2',
                position2,
                group: group,
              ),
              generation: const RequestGeneration(2),
            ),
            value: 'metadata-2',
          ),
        ),
        GroupInstallOutcome.rejected,
      );
      expect(display.installed, isEmpty);
    },
  );

  test('a revoked member cannot come back to complete its group', () async {
    final position2 = testPosition('epoch-a', 2);
    final group = testGroup(
      id: 'message-2',
      position: position2,
      changed: <ResourceFieldGroup<Object?>>[body, metadata],
    );
    final bodyResult = preparedAt(body, 'body-2', position2, group: group);
    expect(await offer(bodyResult, 1), GroupInstallOutcome.staged);

    runtime.revoke(body.resource);

    expect(
      display.offer(
        PreparedResource<String>(
          request: PreparationRequest<String>.fromSnapshot(
            snapshot: bodyResult,
            generation: const RequestGeneration(1),
          ),
          value: 'body-2',
        ),
      ),
      GroupInstallOutcome.rejected,
      reason: 'the member was prepared before the withdrawal',
    );
    expect(display.current(body), isNull);
    expect(display.installed, isEmpty);

    // A sibling prepared after the withdrawal may be staged, but it cannot make
    // the group visible on its own without the member that is gone.
    expect(
      await offer(
        preparedAt(metadata, 'metadata-2', position2, group: group),
        2,
      ),
      GroupInstallOutcome.staged,
    );
    expect(display.current(metadata), isNull);
    expect(display.installed, isEmpty);
    expect(display.gateFor(group)?.pending, hasLength(1));
  });

  test('a newer position supersedes a group that was still staging', () async {
    final position2 = testPosition('epoch-a', 2);
    final position3 = testPosition('epoch-a', 3);
    final oldGroup = testGroup(
      id: 'message-2',
      position: position2,
      changed: <ResourceFieldGroup<Object?>>[body, metadata],
    );
    final newGroup = testGroup(
      id: 'message-3',
      position: position3,
      changed: <ResourceFieldGroup<Object?>>[body, metadata],
    );
    expect(
      await offer(preparedAt(body, 'body-1', testPosition('epoch-a', 1)), 1),
      GroupInstallOutcome.installed,
    );
    expect(
      await offer(preparedAt(body, 'body-2', position2, group: oldGroup), 2),
      GroupInstallOutcome.staged,
    );

    expect(
      await offer(preparedAt(body, 'body-3', position3, group: newGroup), 3),
      GroupInstallOutcome.staged,
    );
    expect(display.current(body)?.value, 'body-1');

    expect(
      await offer(
        preparedAt(metadata, 'metadata-3', position3, group: newGroup),
        4,
      ),
      GroupInstallOutcome.installed,
    );
    expect(display.current(body)?.value, 'body-3');
    expect(display.current(metadata)?.value, 'metadata-3');

    // The superseded group's own member cannot install after the newer
    // position took over the field group.
    expect(
      display.offer(
        PreparedResource<String>(
          request: PreparationRequest<String>.fromSnapshot(
            snapshot: preparedAt(body, 'body-2', position2, group: oldGroup),
            generation: const RequestGeneration(2),
          ),
          value: 'body-2',
        ),
      ),
      GroupInstallOutcome.rejected,
    );
    expect(display.current(body)?.value, 'body-3');
  });

  test(
    'disposal makes staged members un-installable and hides everything',
    () async {
      final position2 = testPosition('epoch-a', 2);
      final group = testGroup(
        id: 'message-2',
        position: position2,
        changed: <ResourceFieldGroup<Object?>>[body, metadata],
      );
      expect(
        await offer(preparedAt(body, 'body-1', testPosition('epoch-a', 1)), 1),
        GroupInstallOutcome.installed,
      );
      expect(
        await offer(preparedAt(body, 'body-2', position2, group: group), 2),
        GroupInstallOutcome.staged,
      );

      runtime.dispose();

      expect(display.installed, isEmpty);
      expect(
        await offer(
          preparedAt(metadata, 'metadata-2', position2, group: group),
          3,
        ),
        GroupInstallOutcome.rejected,
      );
    },
  );
}
