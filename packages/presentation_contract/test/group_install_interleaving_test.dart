import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:test/test.dart';

const _resource = ResourceKey(
  scope: ResourceScope('synthetic'),
  stableKey: 'message',
);
const _body = ResourceFieldGroup<String>(resource: _resource, name: 'body');
const _meta = ResourceFieldGroup<String>(resource: _resource, name: 'meta');
const _position = SourcePosition(
  epoch: SourceEpoch('source-a'),
  version: SourceVersion(2),
);

ConsistencyGroup _group({
  SourcePosition position = _position,
  String id = 'group',
}) => ConsistencyGroup(
  id: ConsistencyGroupId(id),
  position: position,
  changed: [ChangedFieldGroup.of(_body), ChangedFieldGroup.of(_meta)],
);

PreparedResource<String> _member(
  ResourceFieldGroup<String> fields,
  ConsistencyGroup group, {
  SourcePosition? position,
  int generation = 1,
}) => PreparedResource(
  request: PreparationRequest(
    resource: fields,
    source: position ?? group.position,
    generation: RequestGeneration(generation),
    consistencyGroup: group,
  ),
  value: '${fields.name}@${group.position.version.value}',
);

PreparationAcceptance<String> _accept(PreparedResource<String> result) =>
    PreparationAcceptance(request: result.request);

void main() {
  test('invalid members cannot complete a partially prepared group', () {
    final group = _group();
    final gate = ConsistencyGroupInstall<String>(group);
    final first = _member(_body, group);
    expect(gate.offer(first, _accept(first)), GroupInstallOutcome.staged);

    const reconnected = SourcePosition(
      epoch: SourceEpoch('source-b'),
      version: SourceVersion(2),
    );
    const older = SourcePosition(
      epoch: SourceEpoch('source-a'),
      version: SourceVersion(1),
    );
    final invalid = [
      _member(_meta, _group(position: reconnected)),
      _member(_meta, _group(position: older)),
      _member(_meta, _group(id: 'other-group')),
      _member(_meta, group, position: older),
      _member(
        const ResourceFieldGroup<String>(resource: _resource, name: 'other'),
        group,
      ),
      _member(
        const ResourceFieldGroup<String>(
          resource: ResourceKey(
            scope: ResourceScope('switched-scope'),
            stableKey: 'message',
          ),
          name: 'meta',
        ),
        group,
      ),
    ];
    for (final result in invalid) {
      expect(gate.offer(result, _accept(result)), GroupInstallOutcome.rejected);
      expect(gate.staged, {_body: first});
      expect(gate.installed, isEmpty);
      expect(gate.pending, {ChangedFieldGroup.of(_meta)});
    }

    final last = _member(_meta, group);
    final recomputed = _member(_meta, group, generation: 2);
    expect(gate.offer(last, _accept(recomputed)), GroupInstallOutcome.rejected);
    expect(gate.installed, isEmpty);
    expect(gate.offer(last, _accept(last)), GroupInstallOutcome.installed);
    expect(gate.installed, {_body: first, _meta: last});
  });

  for (final status in [
    PreparationStatus.revoked,
    PreparationStatus.disposed,
  ]) {
    test('$status immediately clears staged and installed content', () async {
      for (final completeBeforeInvalidation in [false, true]) {
        final group = _group();
        final gate = ConsistencyGroupInstall<String>(group);
        final first = _member(_body, group);
        final last = _member(_meta, group);
        final completion = Completer<PreparedResource<String>>();
        final outcome = completion.future.then(
          (result) => gate.offer(result, _accept(result)),
        );
        expect(gate.offer(first, _accept(first)), GroupInstallOutcome.staged);
        if (completeBeforeInvalidation) {
          expect(
            gate.offer(last, _accept(last)),
            GroupInstallOutcome.installed,
          );
          expect(gate.installed, hasLength(2));
        }

        if (status == PreparationStatus.revoked) {
          gate.revoke();
        } else {
          gate.dispose();
        }
        expect(gate.status, status);
        expect(gate.staged, isEmpty);
        expect(gate.installed, isEmpty);
        expect(gate.isInstalled, isFalse);
        expect(gate.isComplete, isFalse);

        completion.complete(last);
        expect(await outcome, GroupInstallOutcome.rejected);
        expect(gate.installed, isEmpty);
      }
    });
  }
}
