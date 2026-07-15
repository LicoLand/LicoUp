import 'layout_destination_contract.dart';

typedef LayoutDestinationSnapshotListener<Snapshot extends Object> =
    void Function(Snapshot snapshot);

/// Cancellation handle returned by a destination snapshot listener.
abstract interface class LayoutDestinationSnapshotSubscription {
  bool get isCancelled;

  void cancel();
}

/// Pure semantic data port consumed by a layout-owned destination renderer.
///
/// Implementations expose immutable snapshots and semantic actions only. They
/// must not expose presentation objects or application implementation owners.
abstract interface class LayoutDestinationPort<Snapshot extends Object> {
  LayoutDestinationContract<Snapshot> get contract;

  Snapshot get snapshot;

  LayoutDestinationSnapshotSubscription listen(
    LayoutDestinationSnapshotListener<Snapshot> listener, {
    bool emitCurrent = true,
  });
}
