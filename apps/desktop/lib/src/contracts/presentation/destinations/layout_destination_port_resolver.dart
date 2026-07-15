import 'layout_destination_contract.dart';
import 'layout_destination_port.dart';

/// Type-erased registration boundary used only to hold heterogeneous ports.
///
/// Resolution remains generic, so no untyped snapshot storage crosses the
/// public contract.
abstract interface class LayoutDestinationPortRegistration {
  LayoutDestinationContractKey get key;

  Type get snapshotType;

  LayoutDestinationPort<Snapshot> resolve<Snapshot extends Object>(
    LayoutDestinationContract<Snapshot> contract,
  );
}

/// A type-preserving registration for one semantic destination port.
final class LayoutDestinationPortBinding<Snapshot extends Object>
    implements LayoutDestinationPortRegistration {
  const LayoutDestinationPortBinding(this.port);

  final LayoutDestinationPort<Snapshot> port;

  @override
  LayoutDestinationContractKey get key => port.contract.key;

  @override
  Type get snapshotType => Snapshot;

  @override
  LayoutDestinationPort<RequestedSnapshot> resolve<
    RequestedSnapshot extends Object
  >(LayoutDestinationContract<RequestedSnapshot> contract) {
    if (contract.key != key) {
      throw StateError('layout_destination_contract_key_mismatch');
    }
    if (contract.snapshotType != snapshotType ||
        port is! LayoutDestinationPort<RequestedSnapshot>) {
      throw StateError('layout_destination_contract_type_mismatch');
    }
    return port as LayoutDestinationPort<RequestedSnapshot>;
  }
}

/// Scoped, typed access to a destination port.
///
/// A lease is valid until released through the resolver that acquired it.
final class LayoutDestinationPortLease<Snapshot extends Object> {
  LayoutDestinationPortLease._({
    required LayoutDestinationPortResolver owner,
    required _LayoutDestinationLeaseIdentity identity,
    required LayoutDestinationPort<Snapshot> port,
  }) : _owner = owner,
       _identity = identity,
       _port = port;

  final LayoutDestinationPortResolver _owner;
  final _LayoutDestinationLeaseIdentity _identity;
  final LayoutDestinationPort<Snapshot> _port;
  bool _isReleased = false;

  LayoutDestinationContractKey get key => _identity.key;

  bool get isReleased => _isReleased;

  LayoutDestinationPort<Snapshot> get port {
    if (_isReleased) {
      throw StateError('layout_destination_port_lease_released');
    }
    return _port;
  }
}

/// Resolves semantic destination contracts and owns their lease lifecycle.
final class LayoutDestinationPortResolver {
  factory LayoutDestinationPortResolver(
    Iterable<LayoutDestinationPortRegistration> registrations,
  ) {
    final byKey =
        <LayoutDestinationContractKey, LayoutDestinationPortRegistration>{};
    for (final registration in registrations) {
      if (byKey.containsKey(registration.key)) {
        throw ArgumentError.value(
          registration.key,
          'registrations',
          'layout_destination_contract_key_duplicate',
        );
      }
      byKey[registration.key] = registration;
    }
    return LayoutDestinationPortResolver._(byKey);
  }

  LayoutDestinationPortResolver._(this._registrations);

  final Map<LayoutDestinationContractKey, LayoutDestinationPortRegistration>
  _registrations;
  final Set<_LayoutDestinationLeaseIdentity> _activeLeases = {};
  bool _isClosed = false;

  bool get isClosed => _isClosed;

  int get activeLeaseCount => _activeLeases.length;

  Set<LayoutDestinationContractKey> get contractKeys =>
      Set.unmodifiable(_registrations.keys);

  LayoutDestinationPortLease<Snapshot> acquire<Snapshot extends Object>(
    LayoutDestinationContract<Snapshot> contract,
  ) {
    if (_isClosed) {
      throw StateError('layout_destination_port_resolver_closed');
    }
    final registration = _registrations[contract.key];
    if (registration == null) {
      throw StateError('layout_destination_contract_not_found');
    }
    if (registration.snapshotType != contract.snapshotType) {
      throw StateError('layout_destination_contract_type_mismatch');
    }

    final port = registration.resolve(contract);
    if (port.contract != contract) {
      throw StateError('layout_destination_contract_registration_invalid');
    }
    final identity = _LayoutDestinationLeaseIdentity(contract.key);
    _activeLeases.add(identity);
    return LayoutDestinationPortLease._(
      owner: this,
      identity: identity,
      port: port,
    );
  }

  void release<Snapshot extends Object>(
    LayoutDestinationPortLease<Snapshot> lease,
  ) {
    if (!identical(lease._owner, this)) {
      throw StateError('layout_destination_port_lease_foreign');
    }
    if (!_activeLeases.remove(lease._identity) || lease._isReleased) {
      throw StateError('layout_destination_port_lease_released');
    }
    lease._isReleased = true;
  }

  void close() {
    if (_isClosed) {
      return;
    }
    if (_activeLeases.isNotEmpty) {
      throw StateError('layout_destination_port_resolver_active_leases');
    }
    _isClosed = true;
  }
}

final class _LayoutDestinationLeaseIdentity {
  _LayoutDestinationLeaseIdentity(this.key);

  final LayoutDestinationContractKey key;
}
