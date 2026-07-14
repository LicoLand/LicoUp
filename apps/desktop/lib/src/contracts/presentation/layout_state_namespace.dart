import 'layout_environment.dart';
import 'layout_profile.dart';
import 'semantic_destination.dart';

/// A bounded presentation-state address declared by a profile manifest.
final class LayoutStateNamespace implements Comparable<LayoutStateNamespace> {
  factory LayoutStateNamespace({
    required LayoutProfileId profileId,
    required LayoutRuntimeSurface surface,
    required ClientSection destination,
    required String surfaceId,
  }) {
    if (!_surfaceIdPattern.hasMatch(surfaceId)) {
      throw const FormatException('layout_state_surface_id_invalid');
    }
    return LayoutStateNamespace._(
      profileId: profileId,
      surface: surface,
      destination: destination,
      surfaceId: surfaceId,
    );
  }

  const LayoutStateNamespace._({
    required this.profileId,
    required this.surface,
    required this.destination,
    required this.surfaceId,
  });

  static final RegExp _surfaceIdPattern = RegExp(r'^[a-z]+(?:-[a-z]+)*$');

  final LayoutProfileId profileId;
  final LayoutRuntimeSurface surface;
  final ClientSection destination;
  final String surfaceId;

  @override
  int compareTo(LayoutStateNamespace other) {
    final profileOrder = profileId.compareTo(other.profileId);
    if (profileOrder != 0) {
      return profileOrder;
    }
    final surfaceOrder = surface.index.compareTo(other.surface.index);
    if (surfaceOrder != 0) {
      return surfaceOrder;
    }
    final destinationOrder = destination.index.compareTo(
      other.destination.index,
    );
    return destinationOrder != 0
        ? destinationOrder
        : surfaceId.compareTo(other.surfaceId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutStateNamespace &&
          other.profileId == profileId &&
          other.surface == surface &&
          other.destination == destination &&
          other.surfaceId == surfaceId;

  @override
  int get hashCode => Object.hash(profileId, surface, destination, surfaceId);
}
