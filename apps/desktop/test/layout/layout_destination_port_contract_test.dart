import 'package:licoup/src/contracts/presentation/destinations/destinations.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const key = LayoutDestinationContractKey(
    surface: LayoutRuntimeSurface.desktop,
    destination: ClientSection.agents,
  );
  const contract = LayoutDestinationContract<_FixtureSnapshot>(key: key);

  test(
    'contract key is immutable value identity without a profile dimension',
    () {
      const equivalent = LayoutDestinationContractKey(
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.agents,
      );

      expect(key, equivalent);
      final identities = <LayoutDestinationContractKey>{}
        ..add(key)
        ..add(equivalent);
      expect(identities, hasLength(1));
      expect(contract.snapshotType, _FixtureSnapshot);
    },
  );

  test('snapshot listener emits current and subsequent immutable values', () {
    final port = _FixturePort(contract, const _FixtureSnapshot(1));
    final observed = <_FixtureSnapshot>[];
    final subscription = port.listen(observed.add);

    port.publish(const _FixtureSnapshot(2));
    subscription.cancel();
    port.publish(const _FixtureSnapshot(3));

    expect(observed, const [_FixtureSnapshot(1), _FixtureSnapshot(2)]);
    expect(subscription.isCancelled, isTrue);
  });

  test('repeated acquire creates independent leases for the same port', () {
    final port = _FixturePort(contract, const _FixtureSnapshot(1));
    final resolver = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(port),
    ]);

    expect(resolver.contractKeys, {contract.key});

    final first = resolver.acquire(contract);
    final second = resolver.acquire(contract);

    expect(first, isNot(same(second)));
    expect(first.port, same(port));
    expect(second.port, same(port));
    expect(resolver.activeLeaseCount, 2);

    resolver.release(first);
    expect(first.isReleased, isTrue);
    expect(second.isReleased, isFalse);
    expect(second.port.snapshot, const _FixtureSnapshot(1));
    expect(resolver.activeLeaseCount, 1);

    resolver.release(second);
    resolver.close();
    expect(resolver.isClosed, isTrue);
  });

  test('duplicate release and access after release fail closed', () {
    final resolver = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(
        _FixturePort(contract, const _FixtureSnapshot(1)),
      ),
    ]);
    final lease = resolver.acquire(contract);

    resolver.release(lease);

    expect(
      () => resolver.release(lease),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'layout_destination_port_lease_released',
        ),
      ),
    );
    expect(() => lease.port, throwsStateError);
  });

  test('wrong key cannot resolve a registered port', () {
    final resolver = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(
        _FixturePort(contract, const _FixtureSnapshot(1)),
      ),
    ]);
    const unknown = LayoutDestinationContract<_FixtureSnapshot>(
      key: LayoutDestinationContractKey(
        surface: LayoutRuntimeSurface.mobile,
        destination: ClientSection.agents,
      ),
    );

    expect(
      () => resolver.acquire(unknown),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'layout_destination_contract_not_found',
        ),
      ),
    );
  });

  test('snapshot type mismatch fails before an untyped value can escape', () {
    final resolver = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(
        _FixturePort(contract, const _FixtureSnapshot(1)),
      ),
    ]);
    const wrongType = LayoutDestinationContract<_OtherSnapshot>(key: key);

    expect(
      () => resolver.acquire(wrongType),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'layout_destination_contract_type_mismatch',
        ),
      ),
    );
  });

  test('duplicate keys and foreign leases are rejected', () {
    final firstPort = _FixturePort(contract, const _FixtureSnapshot(1));
    final secondPort = _FixturePort(contract, const _FixtureSnapshot(2));

    expect(
      () => LayoutDestinationPortResolver([
        LayoutDestinationPortBinding(firstPort),
        LayoutDestinationPortBinding(secondPort),
      ]),
      throwsArgumentError,
    );

    final firstResolver = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(firstPort),
    ]);
    final secondResolver = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(secondPort),
    ]);
    final lease = firstResolver.acquire(contract);

    expect(() => secondResolver.release(lease), throwsStateError);
    expect(lease.isReleased, isFalse);
    firstResolver.release(lease);
  });

  test('resolver cannot close with leases or acquire after closing', () {
    final resolver = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(
        _FixturePort(contract, const _FixtureSnapshot(1)),
      ),
    ]);
    final lease = resolver.acquire(contract);

    expect(() => resolver.close(), throwsStateError);
    resolver.release(lease);
    resolver.close();
    resolver.close();

    expect(() => resolver.acquire(contract), throwsStateError);
  });
}

final class _FixtureSnapshot {
  const _FixtureSnapshot(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _FixtureSnapshot && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class _OtherSnapshot {
  const _OtherSnapshot();
}

final class _FixturePort implements LayoutDestinationPort<_FixtureSnapshot> {
  _FixturePort(this.contract, this._snapshot);

  @override
  final LayoutDestinationContract<_FixtureSnapshot> contract;

  _FixtureSnapshot _snapshot;
  final Set<LayoutDestinationSnapshotListener<_FixtureSnapshot>> _listeners =
      {};

  @override
  _FixtureSnapshot get snapshot => _snapshot;

  @override
  LayoutDestinationSnapshotSubscription listen(
    LayoutDestinationSnapshotListener<_FixtureSnapshot> listener, {
    bool emitCurrent = true,
  }) {
    _listeners.add(listener);
    if (emitCurrent) {
      listener(_snapshot);
    }
    return _FixtureSubscription(() => _listeners.remove(listener));
  }

  void publish(_FixtureSnapshot snapshot) {
    _snapshot = snapshot;
    for (final listener in Set.of(_listeners)) {
      listener(snapshot);
    }
  }
}

final class _FixtureSubscription
    implements LayoutDestinationSnapshotSubscription {
  _FixtureSubscription(this._onCancel);

  final void Function() _onCancel;
  bool _isCancelled = false;

  @override
  bool get isCancelled => _isCancelled;

  @override
  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _onCancel();
  }
}
