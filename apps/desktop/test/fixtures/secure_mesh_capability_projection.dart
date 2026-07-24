import 'dart:convert';

import 'package:licoup/src/contracts/generated/secure_mesh_capability_catalog.g.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

final List<Map<String, dynamic>> _catalogDefinitions =
    ((jsonDecode(secureMeshCapabilityCatalogSource)
                as Map<String, dynamic>)['capabilities']
            as List<dynamic>)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList(growable: false);

final List<String> _catalogIds = _catalogDefinitions
    .map((definition) => definition['id']! as String)
    .toList(growable: false);

final Set<String> _mandatoryProtocolFacts = _catalogDefinitions
    .where(
      (definition) =>
          definition['mandatory'] == true && definition['derived'] == false,
    )
    .map((definition) => definition['id']! as String)
    .toSet();

Map<String, dynamic> activeSecureMeshCapabilityProjectionFixture() {
  final local = secureMeshCapabilitySetFixture(
    supported: _mandatoryProtocolFacts,
    unavailable: const {'custody.os_secure_store'},
    reasonOverrides: const {
      'custody.os_secure_store': 'os_secure_store_not_available',
    },
  );
  final peer = secureMeshCapabilitySetFixture(
    supported: {..._mandatoryProtocolFacts, 'custody.os_secure_store'},
  );
  final localEnabled = (local['enabled']! as List<dynamic>)
      .cast<String>()
      .toSet();
  final peerEnabled = (peer['enabled']! as List<dynamic>)
      .cast<String>()
      .toSet();
  return {
    'schemaVersion': secureMeshCapabilityProjectionSchemaVersion,
    'local': local,
    'peer': peer,
    'negotiatedProtocolCapabilities': _catalogIds
        .where(
          (id) =>
              id.startsWith('protocol.') &&
              localEnabled.contains(id) &&
              peerEnabled.contains(id),
        )
        .toList(),
    'reasons': <String, String>{},
  };
}

Map<String, dynamic> localOnlySecureMeshCapabilityProjectionFixture() {
  final projection = activeSecureMeshCapabilityProjectionFixture();
  projection['peer'] = null;
  projection['negotiatedProtocolCapabilities'] = <String>[];
  projection['reasons'] = <String, String>{
    'negotiated_protocol_capabilities': 'secure_mesh_session_not_established',
    'peer': 'secure_mesh_peer_capability_proof_not_available',
  };
  return projection;
}

Map<String, dynamic> secureMeshCapabilitySetFixture({
  Set<String> supported = const {},
  Set<String> unavailable = const {},
  Map<String, String> reasonOverrides = const {},
}) {
  final availableCapabilities = <String>{};
  final enabled = <String>{};
  for (final definition in _catalogDefinitions) {
    final id = definition['id']! as String;
    final prerequisites = (definition['prerequisites']! as List<dynamic>)
        .cast<String>();
    final dependenciesEnabled = prerequisites.every(enabled.contains);
    final isAvailable = definition['derived'] == true
        ? dependenciesEnabled
        : supported.contains(id);
    if (isAvailable) {
      availableCapabilities.add(id);
    }
    if (isAvailable && dependenciesEnabled) {
      enabled.add(id);
    }
  }

  final unavailableCapabilities = unavailable.difference(availableCapabilities);
  final unverified = _catalogIds
      .where(
        (id) =>
            !availableCapabilities.contains(id) &&
            !unavailableCapabilities.contains(id),
      )
      .toSet();
  final missingMandatory = _catalogDefinitions
      .where(
        (definition) =>
            definition['mandatory'] == true &&
            !enabled.contains(definition['id']),
      )
      .map((definition) => definition['id']! as String)
      .toSet();
  final reasonIds = _catalogIds.where((id) => !enabled.contains(id)).toList()
    ..sort();
  final reasons = <String, String>{
    for (final id in reasonIds)
      id:
          reasonOverrides[id] ??
          (availableCapabilities.contains(id)
              ? 'capability_dependency_unmet'
              : unavailableCapabilities.contains(id)
              ? 'capability_not_supported'
              : 'capability_unverified'),
  };

  return {
    'schemaVersion': secureMeshCapabilityProjectionSchemaVersion,
    'catalogDigest': secureMeshCapabilityCatalogDigest,
    'mandatoryFoundationComplete': missingMandatory.isEmpty,
    'enabled': _orderedIds(enabled),
    'available': _orderedIds(availableCapabilities),
    'unavailable': _orderedIds(unavailableCapabilities),
    'unverified': _orderedIds(unverified),
    'missingMandatory': _orderedIds(missingMandatory),
    'reasons': reasons,
    'custody': enabled.contains('custody.os_secure_store')
        ? {
            'strategy': 'os_secure_store',
            'restartSemantics': 'persistent_state_available',
            'enabledHardening': _orderedIds(
              enabled.where((id) => id.startsWith('custody.')).toSet(),
            ),
          }
        : {
            'strategy': 'memory_only_ephemeral',
            'restartSemantics': 're_pair_rekey_after_restart',
            'enabledHardening': ['custody.memory_only_ephemeral'],
          },
  };
}

List<String> _orderedIds(Set<String> selected) =>
    _catalogIds.where(selected.contains).toList();
