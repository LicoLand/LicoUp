import 'layout_environment.dart';
import 'layout_profile.dart';
import 'semantic_destination.dart';

enum LayoutStateValueKind { scroll, paneExtent, expansion, tab }

/// Typed semantic channel for presentation-only state.
///
/// Profiles declare channels; callers cannot invent an untyped string key.
final class LayoutStateChannel {
  const LayoutStateChannel(this.id, this.valueKind);

  final String id;
  final LayoutStateValueKind valueKind;
}

abstract final class LayoutStateChannels {
  static const agentsHistory = LayoutStateChannel(
    'agents-history',
    LayoutStateValueKind.expansion,
  );
  static const agentsSidebar = LayoutStateChannel(
    'agents-sidebar',
    LayoutStateValueKind.paneExtent,
  );
  static const settingsScroll = LayoutStateChannel(
    'settings-scroll',
    LayoutStateValueKind.scroll,
  );
  static const settingsSection = LayoutStateChannel(
    'settings-section',
    LayoutStateValueKind.tab,
  );
  static const settingsIndex = LayoutStateChannel(
    'settings-index',
    LayoutStateValueKind.paneExtent,
  );
  static const communicationSection = LayoutStateChannel(
    'communication-section',
    LayoutStateValueKind.tab,
  );
}

/// A bounded presentation-state address declared by a profile manifest.
final class LayoutStateNamespace implements Comparable<LayoutStateNamespace> {
  factory LayoutStateNamespace({
    required LayoutProfileId profileId,
    required LayoutRuntimeSurface surface,
    required ClientSection destination,
    required LayoutStateChannel channel,
  }) {
    if (!_surfaceIdPattern.hasMatch(channel.id)) {
      throw const FormatException('layout_state_surface_id_invalid');
    }
    return LayoutStateNamespace._(
      profileId: profileId,
      surface: surface,
      destination: destination,
      surfaceId: channel.id,
      valueKind: channel.valueKind,
    );
  }

  const LayoutStateNamespace._({
    required this.profileId,
    required this.surface,
    required this.destination,
    required this.surfaceId,
    required this.valueKind,
  });

  static final RegExp _surfaceIdPattern = RegExp(r'^[a-z]+(?:-[a-z]+)*$');

  final LayoutProfileId profileId;
  final LayoutRuntimeSurface surface;
  final ClientSection destination;
  final String surfaceId;
  final LayoutStateValueKind valueKind;

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
    if (destinationOrder != 0) {
      return destinationOrder;
    }
    final surfaceIdOrder = surfaceId.compareTo(other.surfaceId);
    return surfaceIdOrder != 0
        ? surfaceIdOrder
        : valueKind.index.compareTo(other.valueKind.index);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutStateNamespace &&
          other.profileId == profileId &&
          other.surface == surface &&
          other.destination == destination &&
          other.surfaceId == surfaceId &&
          other.valueKind == valueKind;

  @override
  int get hashCode =>
      Object.hash(profileId, surface, destination, surfaceId, valueKind);
}
