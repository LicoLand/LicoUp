import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

/// Mutable synthetic presentation source for feature widget tests.
///
/// It mirrors the production adapter semantics: an open delivers the current
/// value as the initial snapshot, and every publish emits one base-matched
/// change inside a single-member consistency group. Versions are monotonic
/// inside the source epoch, so the runtime store installs them in order.
final class PresentationSourceFixture<T> implements PresentationSource<T> {
  PresentationSourceFixture({
    required this.fieldGroup,
    required T initial,
    String? epochId,
  }) : _value = initial,
       _epoch = SourceEpoch(epochId ?? 'fixture-${_epochCounter++}');

  @override
  final ResourceFieldGroup<T> fieldGroup;

  static int _epochCounter = 0;

  final SourceEpoch _epoch;
  final List<StreamController<SourceChange<T>>> _openControllers =
      <StreamController<SourceChange<T>>>[];
  T _value;
  int _version = 0;
  int _openCount = 0;
  int _closeCount = 0;

  T get value => _value;

  /// How many observations are currently open; used to assert lazy settings
  /// subscription behavior.
  int get openCount => _openCount;

  /// How many observations have been closed.
  int get closeCount => _closeCount;

  void publish(T value, {TraceContext? trace}) {
    _value = value;
    _version += 1;
    if (_openControllers.isEmpty) return;
    final position = SourcePosition(
      epoch: _epoch,
      version: SourceVersion(_version),
    );
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        '${fieldGroup.resource.stableKey}-${position.version.value}',
        source: SourceIdentity(
          scope: fieldGroup.resource.scope,
          stableKey: fieldGroup.resource.stableKey,
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    final snapshot = ResourceSnapshot<T>(
      fieldGroup: fieldGroup,
      epoch: position.epoch,
      version: position.version,
      value: value,
      consistencyGroup: group,
    );
    for (final controller in List.of(_openControllers)) {
      if (controller.isClosed) continue;
      final base = SourcePosition(
        epoch: _epoch,
        version: SourceVersion(_version - 1),
      );
      controller.add(
        SourceChange<T>(snapshot: snapshot, base: base, group: group),
      );
    }
  }

  @override
  Future<SourceObservation<T>> open() async {
    _version += 1;
    _openCount += 1;
    final controller = StreamController<SourceChange<T>>(sync: true);
    _openControllers.add(controller);
    controller.onCancel = () async {
      _openControllers.remove(controller);
      _openCount -= 1;
      _closeCount += 1;
    };
    return SourceObservation<T>(
      initial: ResourceSnapshot<T>(
        fieldGroup: fieldGroup,
        epoch: _epoch,
        version: SourceVersion(_version),
        value: _value,
      ),
      changes: controller.stream,
    );
  }

  Future<void> dispose() async {
    for (final controller in List.of(_openControllers)) {
      if (!controller.isClosed) await controller.close();
    }
    _openControllers.clear();
  }
}
