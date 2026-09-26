import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

const ResourceScope testScope = ResourceScope('v7-resources');

ResourceKey testResource(String id) =>
    ResourceKey(scope: testScope, stableKey: id);

SourcePosition testPosition(String epoch, int version) =>
    SourcePosition(epoch: SourceEpoch(epoch), version: SourceVersion(version));

ResourceSnapshot<T> testSnapshot<T>({
  required ResourceFieldGroup<T> fieldGroup,
  required SourcePosition position,
  required T value,
  ConsistencyGroup? group,
}) => ResourceSnapshot<T>(
  fieldGroup: fieldGroup,
  epoch: position.epoch,
  version: position.version,
  value: value,
  consistencyGroup: group,
);

ConsistencyGroup testGroup({
  required String id,
  required SourcePosition position,
  required Iterable<ResourceFieldGroup<Object?>> changed,
}) => ConsistencyGroup(
  id: ConsistencyGroupId(
    id,
    source: SourceIdentity(scope: testScope, stableKey: 'test-source'),
  ),
  position: position,
  changed: <ChangedFieldGroup>[
    for (final group in changed) ChangedFieldGroup.of(group),
  ],
);

SourceChange<T> testChange<T>({
  required ResourceSnapshot<T> snapshot,
  required SourcePosition base,
  required ConsistencyGroup group,
}) => SourceChange<T>(snapshot: snapshot, base: base, group: group);

/// Lets the microtask chains of an observation and a preparation finish.
Future<void> settle() async {
  for (var index = 0; index < 6; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// One scripted incarnation of a test source.
///
/// An incarnation stands for one source session: its stream can end, and the
/// value a later open of the same incarnation reports is the incarnation's
/// current value, not the one it started with.
final class TestIncarnation<T> {
  TestIncarnation(this.initial) {
    changes = StreamController<SourceChange<T>>.broadcast(
      sync: true,
      onCancel: () => cancels++,
    );
  }

  ResourceSnapshot<T> initial;
  late final StreamController<SourceChange<T>> changes;
  int cancels = 0;

  ResourceFieldGroup<T> get fieldGroup => initial.fieldGroup;

  /// The value a later open of this incarnation reports.
  void publish(T value, SourcePosition position) {
    initial = testSnapshot<T>(
      fieldGroup: initial.fieldGroup,
      position: position,
      value: value,
      group: initial.consistencyGroup,
    );
  }

  void emit(SourceChange<T> change) => changes.add(change);

  Future<void> end() async {
    if (changes.isClosed) return;
    await changes.close();
  }
}

/// A source whose incarnations a test scripts explicitly.
final class TestSource<T> implements PresentationSource<T> {
  TestSource({
    required this.fieldGroup,
    required TestIncarnation<T> incarnation,
  }) {
    _incarnations.add(incarnation);
    _served = incarnation;
  }

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final List<TestIncarnation<T>> _incarnations = <TestIncarnation<T>>[];
  late TestIncarnation<T> _served;
  int openCount = 0;

  /// The incarnation the last open returned.
  TestIncarnation<T> get served => _served;

  int get cancelCount {
    var total = 0;
    for (final incarnation in _incarnations) {
      total += incarnation.cancels;
    }
    return total;
  }

  @override
  Future<SourceObservation<T>> open() async {
    final index = openCount < _incarnations.length
        ? openCount
        : _incarnations.length - 1;
    openCount++;
    _served = _incarnations[index];
    return SourceObservation<T>(
      initial: _served.initial,
      changes: _served.changes.stream,
    );
  }

  /// Ends the incarnation now serving and stages a new one, as a source that
  /// reconnected into a new session would.
  Future<TestIncarnation<T>> reconnectWith({
    required T value,
    required SourcePosition position,
  }) async {
    await _served.end();
    final next = TestIncarnation<T>(
      testSnapshot<T>(fieldGroup: fieldGroup, position: position, value: value),
    );
    _incarnations.add(next);
    return next;
  }
}
