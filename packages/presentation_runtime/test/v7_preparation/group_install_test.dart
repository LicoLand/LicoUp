import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/src/cache/byte_lru_cache.dart';
import 'package:presentation_runtime/src/preparation/preparation_manager.dart';
import 'package:presentation_runtime/src/scheduling/preparation_executor.dart';
import 'package:test/test.dart';

const ResourceScope _scope = ResourceScope('v7-install');

ResourceKey _key(String id) => ResourceKey(scope: _scope, stableKey: id);

SourcePosition _position(int version) => SourcePosition(
  epoch: const SourceEpoch('epoch-a'),
  version: SourceVersion(version),
);

void main() {
  late ResourcePreparationManager manager;
  late PreparedResourceInstaller<String> installer;
  late ResourceFieldGroup<String> body;
  late ResourceFieldGroup<String> metadata;
  late List<Map<ResourceFieldGroup<String>, PreparedResource<String>>>
  published;

  setUp(() {
    manager = ResourcePreparationManager(
      executor: BoundedPreparationExecutor(maxInFlightBytes: 4096),
      cache: ByteLruCache<VersionedCacheKey, Object?>(capacityBytes: 4096),
    );
    installer = PreparedResourceInstaller<String>(manager);
    body = ResourceFieldGroup<String>(resource: _key('message'), name: 'body');
    metadata = ResourceFieldGroup<String>(
      resource: _key('message'),
      name: 'metadata',
    );
    published = <Map<ResourceFieldGroup<String>, PreparedResource<String>>>[];
    installer.onInstalled(published.add);
  });

  tearDown(() {
    installer.dispose();
    manager.dispose();
  });

  ResourceSnapshot<String> _snapshot<T>(
    ResourceFieldGroup<String> field,
    String value,
    SourcePosition position, {
    ConsistencyGroup? group,
  }) => ResourceSnapshot<String>(
    fieldGroup: field,
    epoch: position.epoch,
    version: position.version,
    value: value,
    consistencyGroup: group,
  );

  ConsistencyGroup _group(
    String id,
    SourcePosition position,
    Iterable<ResourceFieldGroup<String>> fields,
  ) => ConsistencyGroup(
    id: ConsistencyGroupId(
      id,
      source: const SourceIdentity(scope: _scope, stableKey: 'message'),
    ),
    position: position,
    changed: <ChangedFieldGroup>[
      for (final field in fields) ChangedFieldGroup.of(field),
    ],
  );

  Future<PreparedResource<String>> _prepare(
    ResourceFieldGroup<String> field,
    String value,
    SourcePosition position, {
    ConsistencyGroup? group,
    int generation = 1,
  }) {
    return manager.prepare<String>(
      snapshot: _snapshot(field, value, position, group: group),
      generation: RequestGeneration(generation),
      operation: () => value,
      estimatedBytes: 1,
    );
  }

  test('a consistency group installs all members at once', () async {
    final position2 = _position(2);
    final group = _group('group-2', position2, <ResourceFieldGroup<String>>[
      body,
      metadata,
    ]);
    final initial = await _prepare(body, 'body-1', _position(1));
    expect(
      installer.install(initial, manager.acceptanceFor(initial.request)),
      isTrue,
      reason: 'a result without a consistency group installs on its own',
    );
    expect(installer.current(body)?.value, 'body-1');

    final bodyResult = await _prepare(
      body,
      'body-2',
      position2,
      group: group,
      generation: 2,
    );
    final stagedOutcome = installer.offer(
      bodyResult,
      manager.acceptanceFor(bodyResult.request),
    );
    expect(stagedOutcome, GroupInstallOutcome.staged);
    expect(
      installer.current(body)?.value,
      'body-1',
      reason: 'nothing from the group is visible while it is incomplete',
    );
    final gate = installer.gateFor(group)!;
    expect(gate.pending, hasLength(1));
    expect(gate.isInstalled, isFalse);

    final metadataResult = await _prepare(
      metadata,
      'metadata-2',
      position2,
      group: group,
      generation: 3,
    );
    final installedOutcome = installer.offer(
      metadataResult,
      manager.acceptanceFor(metadataResult.request),
    );
    expect(installedOutcome, GroupInstallOutcome.installed);
    expect(installer.current(body)?.value, 'body-2');
    expect(installer.current(metadata)?.value, 'metadata-2');
    expect(gate.isInstalled, isTrue);
    expect(published, hasLength(2), reason: 'one publish step per install');
    expect(published.last, hasLength(2));
    expect(published.last[body]?.value, 'body-2');
  });

  test(
    'a revoked member revokes the whole group instead of half of it',
    () async {
      final position2 = _position(2);
      final position3 = _position(3);
      final group = _group('group-2', position2, <ResourceFieldGroup<String>>[
        body,
        metadata,
      ]);
      final first = await _prepare(body, 'body-2', position2, group: group);
      expect(
        installer.offer(first, manager.acceptanceFor(first.request)),
        GroupInstallOutcome.staged,
      );

      // The body's authority is revoked before its sibling arrives.
      manager.invalidate(body);
      final second = await _prepare(
        metadata,
        'metadata-2',
        position2,
        group: group,
        generation: 2,
      );
      expect(
        installer.offer(second, manager.acceptanceFor(second.request)),
        GroupInstallOutcome.rejected,
      );
      expect(installer.current(metadata), isNull);
      expect(installer.current(body), isNull);
      expect(installer.trackedGroups, 0);

      // A later, fully authorised group installs normally.
      final freshGroup = _group(
        'group-3',
        position3,
        <ResourceFieldGroup<String>>[body, metadata],
      );
      final bodyFresh = await _prepare(
        body,
        'body-3',
        position3,
        group: freshGroup,
        generation: 3,
      );
      final metadataFresh = await _prepare(
        metadata,
        'metadata-3',
        position3,
        group: freshGroup,
        generation: 4,
      );
      expect(
        installer.offer(bodyFresh, manager.acceptanceFor(bodyFresh.request)),
        GroupInstallOutcome.staged,
      );
      expect(
        installer.offer(
          metadataFresh,
          manager.acceptanceFor(metadataFresh.request),
        ),
        GroupInstallOutcome.installed,
      );
      expect(installer.current(body)?.value, 'body-3');
      expect(installer.current(metadata)?.value, 'metadata-3');
    },
  );

  test('a late result cannot install after revocation', () async {
    final position2 = _position(2);
    final group = _group('group-2', position2, <ResourceFieldGroup<String>>[
      body,
      metadata,
    ]);
    final result = await _prepare(
      body,
      'body-2',
      position2,
      group: group,
      generation: 2,
    );
    final acceptance = manager.acceptanceFor(result.request);
    manager.invalidate(body);

    expect(acceptance.canInstall(result), isTrue, reason: 'captured earlier');
    expect(installer.install(result, acceptance), isFalse);
    expect(installer.offer(result, acceptance), GroupInstallOutcome.rejected);
    expect(installer.current(body), isNull);
    expect(installer.trackedGroups, 0);
  });

  test('a member from another position or field group is rejected', () async {
    final position2 = _position(2);
    final group = _group('group-2', position2, <ResourceFieldGroup<String>>[
      body,
      metadata,
    ]);
    final elsewhere = await _prepare(
      body,
      'body-3',
      _position(3),
      group: group,
      generation: 2,
    );
    expect(
      installer.offer(elsewhere, manager.acceptanceFor(elsewhere.request)),
      GroupInstallOutcome.rejected,
      reason: 'the group installs at its own position',
    );

    final unrelated = ResourceFieldGroup<String>(
      resource: _key('other-message'),
      name: 'body',
    );
    final otherGroup = _group(
      'group-2',
      position2,
      <ResourceFieldGroup<String>>[body, metadata],
    );
    final unrelatedResult = await _prepare(
      unrelated,
      'unrelated',
      position2,
      group: otherGroup,
      generation: 3,
    );
    expect(
      installer.offer(
        unrelatedResult,
        manager.acceptanceFor(unrelatedResult.request),
      ),
      GroupInstallOutcome.rejected,
      reason: 'the group does not affect that field group',
    );
    expect(installer.current(unrelated), isNull);
  });

  test('disposal makes staged members un-installable', () async {
    final position2 = _position(2);
    final group = _group('group-2', position2, <ResourceFieldGroup<String>>[
      body,
      metadata,
    ]);
    final first = await _prepare(body, 'body-2', position2, group: group);
    expect(
      installer.offer(first, manager.acceptanceFor(first.request)),
      GroupInstallOutcome.staged,
    );
    final second = await _prepare(
      metadata,
      'metadata-2',
      position2,
      group: group,
      generation: 2,
    );

    installer.dispose();
    expect(
      installer.offer(second, manager.acceptanceFor(second.request)),
      GroupInstallOutcome.rejected,
    );
    expect(installer.installed, isEmpty);
    expect(installer.trackedGroups, 0);
  });

  test('withdrawing a resource revokes the group it came from', () async {
    final position2 = _position(2);
    final group = _group('group-2', position2, <ResourceFieldGroup<String>>[
      body,
      metadata,
    ]);
    final bodyResult = await _prepare(body, 'body-2', position2, group: group);
    final metadataResult = await _prepare(
      metadata,
      'metadata-2',
      position2,
      group: group,
      generation: 2,
    );
    installer.offer(bodyResult, manager.acceptanceFor(bodyResult.request));
    expect(
      installer.offer(
        metadataResult,
        manager.acceptanceFor(metadataResult.request),
      ),
      GroupInstallOutcome.installed,
    );
    expect(installer.current(body)?.value, 'body-2');

    expect(installer.withdraw(body), isTrue);
    expect(installer.current(body), isNull);
    expect(installer.trackedGroups, 0, reason: 'the group gate is gone');
    expect(installer.current(metadata)?.value, 'metadata-2');
  });

  test('a stale read cannot replace the newest preparation', () async {
    final position2 = _position(2);
    final newest = await _prepare(body, 'body-2', position2, generation: 2);
    expect(
      installer.install(newest, manager.acceptanceFor(newest.request)),
      isTrue,
    );
    expect(installer.current(body)?.value, 'body-2');

    final staleSource = await _prepare(
      body,
      'body-1',
      _position(1),
      generation: 1,
    );
    expect(
      manager.acceptanceFor(staleSource.request).canInstall(staleSource),
      isFalse,
      reason: 'an older source position cannot become current',
    );
    expect(
      installer.install(
        staleSource,
        manager.acceptanceFor(staleSource.request),
      ),
      isFalse,
    );
    expect(installer.current(body)?.value, 'body-2');

    final staleGeneration = await _prepare(
      body,
      'body-2',
      position2,
      generation: 1,
    );
    expect(
      manager
          .acceptanceFor(staleGeneration.request)
          .canInstall(staleGeneration),
      isFalse,
      reason: 'an older request generation cannot become current',
    );
    expect(installer.current(body)?.value, 'body-2');

    final newer = await _prepare(body, 'body-3', _position(3), generation: 3);
    expect(manager.acceptanceFor(newer.request).canInstall(newer), isTrue);
    expect(
      installer.install(newer, manager.acceptanceFor(newer.request)),
      isTrue,
    );
    expect(installer.current(body)?.value, 'body-3');
  });

  test('a newer generation re-stages its group without mixing runs', () async {
    final position2 = _position(2);
    final group = _group('group-2', position2, <ResourceFieldGroup<String>>[
      body,
      metadata,
    ]);
    final body2 = await _prepare(
      body,
      'body-2',
      position2,
      group: group,
      generation: 2,
    );
    final metadata3 = await _prepare(
      metadata,
      'metadata-2',
      position2,
      group: group,
      generation: 3,
    );
    expect(
      installer.offer(body2, manager.acceptanceFor(body2.request)),
      GroupInstallOutcome.staged,
    );
    expect(
      installer.offer(metadata3, manager.acceptanceFor(metadata3.request)),
      GroupInstallOutcome.installed,
    );
    expect(published, hasLength(1));

    // The same position is prepared again under a newer generation after the
    // prepared value left the cache, so the group must be able to re-install.
    manager.cache.clear(force: true);
    final body4 = await _prepare(
      body,
      'body-2b',
      position2,
      group: group,
      generation: 4,
    );
    expect(body4.value, 'body-2b');
    expect(
      installer.offer(body4, manager.acceptanceFor(body4.request)),
      GroupInstallOutcome.staged,
      reason: 'a new run starts instead of ignoring the newer member',
    );
    expect(
      installer.current(body)?.value,
      'body-2',
      reason: 'the installed run stays visible until the new run completes',
    );
    final metadataAgain = await _prepare(
      metadata,
      'metadata-2',
      position2,
      group: group,
      generation: 3,
    );
    expect(
      installer.offer(
        metadataAgain,
        manager.acceptanceFor(metadataAgain.request),
      ),
      GroupInstallOutcome.installed,
    );
    expect(installer.current(body)?.value, 'body-2b');
    expect(published, hasLength(2), reason: 'no republish of the old run');
    expect(published.last[body]?.value, 'body-2b');
    expect(published.last[metadata]?.value, 'metadata-2');
    expect(installer.trackedGroups, 1);
  });

  test('an older position gate is pruned once a newer one installs', () async {
    final position2 = _position(2);
    final position3 = _position(3);
    final early = _group('group-x', position2, <ResourceFieldGroup<String>>[
      body,
      metadata,
    ]);
    final earlyBody = await _prepare(
      body,
      'body-2',
      position2,
      group: early,
      generation: 2,
    );
    final earlyMetadata = await _prepare(
      metadata,
      'metadata-2',
      position2,
      group: early,
      generation: 3,
    );
    expect(
      installer.offer(earlyBody, manager.acceptanceFor(earlyBody.request)),
      GroupInstallOutcome.staged,
    );
    expect(
      installer.offer(
        earlyMetadata,
        manager.acceptanceFor(earlyMetadata.request),
      ),
      GroupInstallOutcome.installed,
    );
    expect(installer.trackedGroups, 1);

    final later = _group('group-x', position3, <ResourceFieldGroup<String>>[
      body,
      metadata,
    ]);
    final laterBody = await _prepare(
      body,
      'body-3',
      position3,
      group: later,
      generation: 4,
    );
    final laterMetadata = await _prepare(
      metadata,
      'metadata-3',
      position3,
      group: later,
      generation: 5,
    );
    expect(
      installer.offer(laterBody, manager.acceptanceFor(laterBody.request)),
      GroupInstallOutcome.staged,
    );
    expect(
      installer.offer(
        laterMetadata,
        manager.acceptanceFor(laterMetadata.request),
      ),
      GroupInstallOutcome.installed,
    );
    expect(
      installer.trackedGroups,
      1,
      reason: 'the superseded position no longer needs its gate',
    );
    expect(installer.gateFor(early), isNull);
    expect(installer.current(body)?.value, 'body-3');
    expect(installer.current(metadata)?.value, 'metadata-3');
  });
}
