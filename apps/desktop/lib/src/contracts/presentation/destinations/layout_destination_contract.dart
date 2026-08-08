import '../layout_environment.dart';
import '../semantic_destination.dart';

/// Semantic identity of one destination contract on one runtime surface.
///
/// Profile identity is intentionally absent: every profile rendering the same
/// surface and destination consumes the same semantic contract.
final class LayoutDestinationContractKey {
  const LayoutDestinationContractKey({
    required this.surface,
    required this.destination,
  });

  final LayoutRuntimeSurface surface;
  final ClientSection destination;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutDestinationContractKey &&
          other.surface == surface &&
          other.destination == destination;

  @override
  int get hashCode => Object.hash(surface, destination);

  @override
  String toString() => '${surface.name}/${destination.name}';
}

/// Typed description of the immutable snapshot carried by a destination port.
final class LayoutDestinationContract<Snapshot extends Object> {
  const LayoutDestinationContract({required this.key});

  final LayoutDestinationContractKey key;

  Type get snapshotType => Snapshot;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutDestinationContract<Snapshot> && other.key == key;

  @override
  int get hashCode => Object.hash(key, Snapshot);

  @override
  String toString() => '$key<$Snapshot>';
}
