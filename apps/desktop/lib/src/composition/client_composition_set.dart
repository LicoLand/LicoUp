import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/client_feature_mounts.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

/// The declaration of which feature mounts a running client owns.
///
/// The declaration is the directory itself: [mounts] holds one entry per
/// feature mount, and each entry carries the destinations and capabilities its
/// own feature declares. `ClientAppComposition` is the only assembly point and
/// constructs exactly the feature compositions the enabled entries name; a
/// feature no entry names has no composition, no binding, no provider override,
/// no destination mount and no surface, so an absent feature cannot start a
/// background owner and cannot be reached from the shell.
///
/// Absence is a property of the directory value the root is given, never a
/// runtime availability check performed while the client is running, and it is
/// never a state the renderer has to discover. Mounting, unmounting and
/// enabling return a new directory, so a client can be given the phase it
/// should run in without any other file changing:
///
/// ```dart
/// final reduced = ClientCompositionSet.fromRequests(
///   ClientFeatureMounts.without([ClientFeatureMounts.models.id]),
/// );
/// ```
///
/// The shell's own feature mounts — the renderer chrome, the conversation
/// planes, the target catalog, the agent catalog and the agent usage surface —
/// are named by both constants because the shell cannot serve its destinations
/// without them. [minimum] and [full] otherwise differ only in the optional
/// mounts that the minimum leaves unmounted.
final class ClientCompositionSet {
  /// The declaration [requests] describes.
  ///
  /// A request that repeats an identity is rejected by the directory, so two
  /// features can never claim the same mount.
  factory ClientCompositionSet.fromRequests(
    Iterable<FeatureMountRequest> requests,
  ) => ClientCompositionSet._(FeatureMountDirectory(requests));

  const ClientCompositionSet._(this.mounts);

  /// The directory of feature mounts this declaration owns.
  final FeatureMountDirectory mounts;

  /// The minimum client: the shell's own mounts, with every optional mount left
  /// unmounted.
  ///
  /// The relay composition belongs to the minimum because the shell cannot
  /// serve the agents destination without it: the agent workspace renders its
  /// remote-approval region from a `MobileRelayBinding`, so an unmounted relay
  /// contributes its absent value rather than a surface of its own. Every other
  /// optional feature is absent, so none of their owners, provider overrides,
  /// destinations or surfaces exist.
  static final ClientCompositionSet minimum = ClientCompositionSet.fromRequests(
    ClientFeatureMounts.minimum,
  );

  /// The full client: the minimum plus every optional feature.
  static final ClientCompositionSet full = ClientCompositionSet.fromRequests(
    ClientFeatureMounts.full,
  );

  /// The agent catalog composition.
  bool get agents => mounts.isEnabled(ClientFeatureMounts.agents.id);

  /// The conversation planes composition.
  bool get conversation =>
      mounts.isEnabled(ClientFeatureMounts.conversation.id);

  /// The target catalog composition.
  bool get targets => mounts.isEnabled(ClientFeatureMounts.targets.id);

  /// The renderer chrome composition.
  bool get chrome => mounts.isEnabled(ClientFeatureMounts.chrome.id);

  /// The agent usage composition.
  bool get monitoring => mounts.isEnabled(ClientFeatureMounts.monitoring.id);

  /// The agent hub composition.
  bool get agentHub => mounts.isEnabled(ClientFeatureMounts.agentHub.id);

  /// The cross-device relay composition.
  ///
  /// Optional, but the agents destination still renders its remote-approval
  /// region: an unmounted relay feature contributes its absent value rather
  /// than a surface of its own.
  bool get mobileRelay => mounts.isEnabled(ClientFeatureMounts.mobileRelay.id);

  /// The model catalog composition.
  bool get models => mounts.isEnabled(ClientFeatureMounts.models.id);

  /// The adapter plugin composition.
  bool get pluginManagement =>
      mounts.isEnabled(ClientFeatureMounts.pluginManagement.id);

  /// The global search composition.
  bool get search => mounts.isEnabled(ClientFeatureMounts.search.id);

  /// The settings composition.
  bool get settings => mounts.isEnabled(ClientFeatureMounts.settings.id);

  /// The skill hub composition.
  bool get skillHub => mounts.isEnabled(ClientFeatureMounts.skillHub.id);

  /// The phase the declaration gives [id]; an identity no entry names is
  /// [FeatureMountPhase.unmounted].
  FeatureMountPhase phaseOf(FeatureMountId id) => mounts.phaseOf(id);

  /// Whether the declaration owns the mount [id] names, at any phase but
  /// [FeatureMountPhase.unmounted].
  bool isFeatureMounted(FeatureMountId id) => mounts.isMounted(id);

  /// Every destination and capability the declaration's enabled entries
  /// contribute.
  Set<MountDestinationId> get destinations => mounts.destinations;

  Set<MountCapabilityId> get capabilities => mounts.capabilities;

  /// Whether the feature that contributes [destination] is mounted.
  ///
  /// This is the single destination-to-feature decision in the client: the
  /// mount directory, the shell renderer and the shell navigation projection
  /// all ask the directory instead of repeating the mapping. A destination no
  /// enabled entry contributes is absent, and no runtime availability probe can
  /// disagree with it.
  bool isInstalled(ClientSection destination) =>
      mounts.contributes(mountDestinationOf(destination));

  @override
  String toString() => 'ClientCompositionSet(${mounts.mounts.length} mounts)';
}
