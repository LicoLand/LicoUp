import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

/// The directory identity of one semantic destination.
///
/// The identity is the destination's own name, so the shell's destination
/// vocabulary and the directory's contribution vocabulary are the same
/// vocabulary by construction: there is no per-destination table that a new
/// [ClientSection] value could fall out of step with.
MountDestinationId mountDestinationOf(ClientSection destination) =>
    MountDestinationId(destination.name);

/// The destination [id] names, or null when this client's destination
/// vocabulary does not contain it.
ClientSection? clientSectionOf(MountDestinationId id) =>
    ClientSection.values.asNameMap()[id.value];

/// Capability identities the client's feature mounts contribute.
///
/// A capability is what one mount offers to the rest of the client without
/// owning a destination: the agent catalog and its conversation planes, the
/// renderer chrome, the model catalog another destination renders its pairing
/// channels from. A mount that needs one declares it as a requirement, and the
/// catalogue serves its surface only while the directory still contributes
/// that capability.
abstract final class ClientCapabilities {
  static const MountCapabilityId agentCatalog = MountCapabilityId(
    'agent-catalog',
  );
  static const MountCapabilityId conversationPlanes = MountCapabilityId(
    'conversation-planes',
  );
  static const MountCapabilityId targetCatalog = MountCapabilityId(
    'target-catalog',
  );
  static const MountCapabilityId rendererChrome = MountCapabilityId(
    'renderer-chrome',
  );
  static const MountCapabilityId agentUsage = MountCapabilityId('agent-usage');
  static const MountCapabilityId agentHub = MountCapabilityId('agent-hub');
  static const MountCapabilityId crossDeviceRelay = MountCapabilityId(
    'cross-device-relay',
  );
  static const MountCapabilityId modelCatalogue = MountCapabilityId(
    'model-catalogue',
  );
  static const MountCapabilityId adapterPlugins = MountCapabilityId(
    'adapter-plugins',
  );
  static const MountCapabilityId globalSearch = MountCapabilityId(
    'global-search',
  );
  static const MountCapabilityId presentationSettings = MountCapabilityId(
    'presentation-settings',
  );
  static const MountCapabilityId skillCatalogue = MountCapabilityId(
    'skill-catalogue',
  );
}

/// One feature mount this client can own.
///
/// The declaration is the feature's own: it names the feature's identity, the
/// destinations it contributes, the capabilities it offers, and whether the
/// minimum client owns it. Nothing else in the client names a feature's
/// destination, so removing one declaration removes exactly one feature's
/// destination and capabilities.
final class ClientFeatureMountDeclaration {
  ClientFeatureMountDeclaration({
    required this.request,
    required this.shellOwned,
  });

  /// The declaration the full client owns.
  final FeatureMountRequest request;

  /// Whether the minimum client owns this mount.
  ///
  /// The shell cannot serve its own destinations without the mounts it declares
  /// here; every other mount is optional.
  final bool shellOwned;

  FeatureMountId get id => request.id;

  /// The declaration as the minimum client requests it.
  FeatureMountRequest get minimum => shellOwned ? request : request.unmounted();

  @override
  String toString() => 'ClientFeatureMountDeclaration(${request.id})';
}

/// The client's feature mount declarations, in directory order.
///
/// This list is the directory: which features the client can own, and what each
/// one contributes. The composition declaration selects the phase of every
/// entry, the shell projection reports the destinations the enabled entries
/// contribute, and the renderer resolves a destination by asking the directory
/// which entry contributes it. A feature whose declaration is removed from this
/// list has no destination, no capability, no surface and no owner.
abstract final class ClientFeatureMounts {
  /// The agent catalog composition: the entry point every client serves.
  static final ClientFeatureMountDeclaration agents =
      ClientFeatureMountDeclaration(
        shellOwned: true,
        request: FeatureMountRequest(
          id: const FeatureMountId('agents'),
          phase: FeatureMountPhase.enabled,
          destinations: <MountDestinationId>[
            mountDestinationOf(ClientSection.agents),
          ],
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.agentCatalog,
          ],
        ),
      );

  /// The conversation planes composition.
  static final ClientFeatureMountDeclaration conversation =
      ClientFeatureMountDeclaration(
        shellOwned: true,
        request: FeatureMountRequest(
          id: const FeatureMountId('conversation'),
          phase: FeatureMountPhase.enabled,
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.conversationPlanes,
          ],
        ),
      );

  /// The target catalog composition.
  static final ClientFeatureMountDeclaration targets =
      ClientFeatureMountDeclaration(
        shellOwned: true,
        request: FeatureMountRequest(
          id: const FeatureMountId('targets'),
          phase: FeatureMountPhase.enabled,
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.targetCatalog,
          ],
        ),
      );

  /// The renderer chrome composition.
  static final ClientFeatureMountDeclaration chrome =
      ClientFeatureMountDeclaration(
        shellOwned: true,
        request: FeatureMountRequest(
          id: const FeatureMountId('chrome'),
          phase: FeatureMountPhase.enabled,
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.rendererChrome,
          ],
        ),
      );

  /// The agent usage composition.
  static final ClientFeatureMountDeclaration monitoring =
      ClientFeatureMountDeclaration(
        shellOwned: true,
        request: FeatureMountRequest(
          id: const FeatureMountId('monitoring'),
          phase: FeatureMountPhase.enabled,
          destinations: <MountDestinationId>[
            mountDestinationOf(ClientSection.monitoring),
          ],
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.agentUsage,
          ],
        ),
      );

  /// The agent hub composition.
  static final ClientFeatureMountDeclaration agentHub =
      ClientFeatureMountDeclaration(
        shellOwned: false,
        request: FeatureMountRequest(
          id: const FeatureMountId('agent-hub'),
          phase: FeatureMountPhase.enabled,
          destinations: <MountDestinationId>[
            mountDestinationOf(ClientSection.agentHub),
          ],
          capabilities: const <MountCapabilityId>[ClientCapabilities.agentHub],
        ),
      );

  /// The cross-device relay composition.
  ///
  /// Optional, and the agent workspace renders its remote-approval region
  /// whether the relay is mounted or not: an unmounted relay contributes its
  /// absent value rather than a surface of its own.
  static final ClientFeatureMountDeclaration mobileRelay =
      ClientFeatureMountDeclaration(
        shellOwned: false,
        request: FeatureMountRequest(
          id: const FeatureMountId('mobile-relay'),
          phase: FeatureMountPhase.enabled,
          destinations: <MountDestinationId>[
            mountDestinationOf(ClientSection.mobileRelay),
          ],
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.crossDeviceRelay,
          ],
        ),
      );

  /// The model catalog composition.
  static final ClientFeatureMountDeclaration models =
      ClientFeatureMountDeclaration(
        shellOwned: false,
        request: FeatureMountRequest(
          id: const FeatureMountId('models'),
          phase: FeatureMountPhase.enabled,
          destinations: <MountDestinationId>[
            mountDestinationOf(ClientSection.models),
          ],
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.modelCatalogue,
          ],
        ),
      );

  /// The adapter plugin composition.
  static final ClientFeatureMountDeclaration pluginManagement =
      ClientFeatureMountDeclaration(
        shellOwned: false,
        request: FeatureMountRequest(
          id: const FeatureMountId('plugin-management'),
          phase: FeatureMountPhase.enabled,
          destinations: <MountDestinationId>[
            mountDestinationOf(ClientSection.pluginManagement),
          ],
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.adapterPlugins,
          ],
        ),
      );

  /// The global search composition.
  static final ClientFeatureMountDeclaration search =
      ClientFeatureMountDeclaration(
        shellOwned: false,
        request: FeatureMountRequest(
          id: const FeatureMountId('search'),
          phase: FeatureMountPhase.enabled,
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.globalSearch,
          ],
        ),
      );

  /// The settings composition.
  static final ClientFeatureMountDeclaration settings =
      ClientFeatureMountDeclaration(
        shellOwned: false,
        request: FeatureMountRequest(
          id: const FeatureMountId('settings'),
          phase: FeatureMountPhase.enabled,
          destinations: <MountDestinationId>[
            mountDestinationOf(ClientSection.settings),
          ],
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.presentationSettings,
          ],
        ),
      );

  /// The skill hub composition.
  static final ClientFeatureMountDeclaration skillHub =
      ClientFeatureMountDeclaration(
        shellOwned: false,
        request: FeatureMountRequest(
          id: const FeatureMountId('skill-hub'),
          phase: FeatureMountPhase.enabled,
          destinations: <MountDestinationId>[
            mountDestinationOf(ClientSection.skillHub),
          ],
          capabilities: const <MountCapabilityId>[
            ClientCapabilities.skillCatalogue,
          ],
        ),
      );

  /// Every feature mount this client can own, in directory order.
  static final List<ClientFeatureMountDeclaration> all =
      List<ClientFeatureMountDeclaration>.unmodifiable(
        <ClientFeatureMountDeclaration>[
          agents,
          conversation,
          targets,
          chrome,
          monitoring,
          agentHub,
          mobileRelay,
          models,
          pluginManagement,
          search,
          settings,
          skillHub,
        ],
      );

  /// The declarations the full client asks for: every mount enabled.
  static List<FeatureMountRequest> get full => <FeatureMountRequest>[
    for (final mount in all) mount.request,
  ];

  /// The declarations the minimum client asks for: the shell's own mounts
  /// enabled, every optional mount left unmounted.
  static List<FeatureMountRequest> get minimum => <FeatureMountRequest>[
    for (final mount in all) mount.minimum,
  ];

  /// The declarations of [requests] without the mounts named by [ids].
  static List<FeatureMountRequest> without(
    Iterable<FeatureMountId> ids, {
    List<FeatureMountRequest>? of,
  }) {
    final removed = Set<FeatureMountId>.of(ids);
    return <FeatureMountRequest>[
      for (final request in of ?? full)
        if (!removed.contains(request.id)) request,
    ];
  }
}
