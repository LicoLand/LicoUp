import 'dart:collection';
import 'dart:convert';

import 'package:flutter_client/src/contracts/generated/secure_mesh_capability_catalog.g.dart';

const int secureMeshCapabilityProjectionSchemaVersion = 3;

final RegExp _capabilityIdPattern = RegExp(
  r'^(?:protocol|custody)\.[a-z0-9][a-z0-9._-]{0,95}$',
);
final RegExp _catalogCapabilityIdPattern = RegExp(
  r'^(?:protocol|custody)\.[a-z0-9_]+$',
);
final RegExp _reasonCodePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,95}$');
final RegExp _sha256DigestPattern = RegExp(r'^[a-f0-9]{64}$');

final _CanonicalCapabilityCatalog _canonicalCapabilityCatalog =
    _CanonicalCapabilityCatalog.fromGeneratedSource();

class SecureMeshCapabilitySetProjection {
  SecureMeshCapabilitySetProjection._({
    required this.schemaVersion,
    required this.catalogDigest,
    required this.mandatoryFoundationComplete,
    required List<String> enabled,
    required List<String> available,
    required List<String> unavailable,
    required List<String> unverified,
    required List<String> missingMandatory,
    required Map<String, String> reasons,
    required this.selectedCustody,
    required List<SecureMeshCapabilityDependency> dependencies,
  }) : enabled = List.unmodifiable(enabled),
       available = List.unmodifiable(available),
       unavailable = List.unmodifiable(unavailable),
       unverified = List.unmodifiable(unverified),
       missingMandatory = List.unmodifiable(missingMandatory),
       reasons = UnmodifiableMapView(reasons),
       dependencies = List.unmodifiable(dependencies);

  factory SecureMeshCapabilitySetProjection.fromJson(
    Map<String, dynamic> json,
  ) {
    _requireExactKeys(json, const {
      'schemaVersion',
      'catalogDigest',
      'mandatoryFoundationComplete',
      'enabled',
      'available',
      'unavailable',
      'unverified',
      'missingMandatory',
      'reasons',
      'custody',
    }, 'capability set projection');
    final schemaVersion = _requiredInt(json, 'schemaVersion');
    if (schemaVersion != secureMeshCapabilityProjectionSchemaVersion) {
      throw const FormatException(
        'Secure Mesh capability projection schema is unsupported.',
      );
    }
    final catalogDigest = _requiredString(json, 'catalogDigest');
    if (_canonicalCapabilityCatalog.schemaVersion !=
            secureMeshCapabilityCatalogSchemaVersion ||
        !_sha256DigestPattern.hasMatch(catalogDigest) ||
        catalogDigest != _canonicalCapabilityCatalog.digest) {
      throw const FormatException(
        'Secure Mesh capability projection catalog binding is invalid.',
      );
    }
    final enabled = _canonicalCapabilitySet(json, 'enabled');
    final available = _canonicalCapabilitySet(json, 'available');
    final unavailable = _canonicalCapabilitySet(json, 'unavailable');
    final unverified = _canonicalCapabilitySet(json, 'unverified');
    final missingMandatory = _canonicalCapabilitySet(json, 'missingMandatory');
    final partition = <String>{};
    for (final set in [available, unavailable, unverified]) {
      for (final capability in set) {
        if (!partition.add(capability)) {
          throw const FormatException(
            'Secure Mesh capability projection sets overlap.',
          );
        }
      }
    }
    if (!_sameSet(partition, _canonicalCapabilityCatalog.ids)) {
      throw const FormatException(
        'Secure Mesh capability projection does not classify every catalog node.',
      );
    }
    if (!enabled.every(available.contains)) {
      throw const FormatException(
        'Secure Mesh capability projection enables an unavailable capability.',
      );
    }
    final expectedEnabled = <String>{};
    for (final definition in _canonicalCapabilityCatalog.definitions) {
      final dependenciesEnabled = definition.prerequisites.every(
        expectedEnabled.contains,
      );
      final isAvailable = available.contains(definition.id);
      if (definition.derived && isAvailable != dependenciesEnabled) {
        throw const FormatException(
          'Secure Mesh derived capability availability is inconsistent.',
        );
      }
      if (isAvailable && dependenciesEnabled) {
        expectedEnabled.add(definition.id);
      }
    }
    if (!_sameSet(enabled, expectedEnabled)) {
      throw const FormatException(
        'Secure Mesh capability dependency closure is invalid.',
      );
    }
    final expectedMissingMandatory = _canonicalCapabilityCatalog.definitions
        .where((definition) => definition.mandatory)
        .map((definition) => definition.id)
        .where((capability) => !expectedEnabled.contains(capability))
        .toSet();
    if (!_sameSet(missingMandatory, expectedMissingMandatory)) {
      throw const FormatException(
        'Secure Mesh mandatory capability projection is invalid.',
      );
    }
    final mandatoryFoundationComplete = _requiredBool(
      json,
      'mandatoryFoundationComplete',
    );
    if (mandatoryFoundationComplete != missingMandatory.isEmpty) {
      throw const FormatException(
        'Secure Mesh mandatory capability projection is inconsistent.',
      );
    }
    final reasons = _reasonMap(json, 'reasons', capabilityKeysOnly: true);
    _requireLexicalKeyOrder(reasons, 'capability reasons');
    final expectedReasonKeys = _canonicalCapabilityCatalog.ids.difference(
      enabled,
    );
    if (!_sameSet(reasons.keys, expectedReasonKeys)) {
      throw const FormatException(
        'Secure Mesh capability reason coverage is incomplete.',
      );
    }
    for (final capability in available.difference(enabled)) {
      if (reasons[capability] != 'capability_dependency_unmet') {
        throw const FormatException(
          'Secure Mesh capability dependency reason is invalid.',
        );
      }
    }
    final selectedCustody = SecureMeshSelectedCustody.fromJson(
      _requiredMap(json, 'custody'),
      enabled: enabled,
    );
    return SecureMeshCapabilitySetProjection._(
      schemaVersion: schemaVersion,
      catalogDigest: catalogDigest,
      mandatoryFoundationComplete: mandatoryFoundationComplete,
      enabled: _orderedByCatalog(enabled),
      available: _orderedByCatalog(available),
      unavailable: _orderedByCatalog(unavailable),
      unverified: _orderedByCatalog(unverified),
      missingMandatory: _orderedByCatalog(missingMandatory),
      reasons: _sortedMap(reasons),
      selectedCustody: selectedCustody,
      dependencies: _canonicalCapabilityCatalog.definitions
          .where((definition) => definition.prerequisites.isNotEmpty)
          .map(
            (definition) => SecureMeshCapabilityDependency(
              capability: definition.id,
              prerequisites: definition.prerequisites,
            ),
          )
          .toList(growable: false),
    );
  }

  final int schemaVersion;
  final String catalogDigest;
  final bool mandatoryFoundationComplete;
  final List<String> enabled;
  final List<String> available;
  final List<String> unavailable;
  final List<String> unverified;
  final List<String> missingMandatory;
  final Map<String, String> reasons;
  final SecureMeshSelectedCustody selectedCustody;
  final List<SecureMeshCapabilityDependency> dependencies;
}

class SecureMeshSelectedCustody {
  const SecureMeshSelectedCustody({
    required this.strategy,
    required this.restartSemantics,
    required this.enabledHardening,
  });

  factory SecureMeshSelectedCustody.fromJson(
    Map<String, dynamic> json, {
    required Set<String> enabled,
  }) {
    _requireExactKeys(json, const {
      'strategy',
      'restartSemantics',
      'enabledHardening',
    }, 'selected custody projection');
    final strategy = _requiredString(json, 'strategy');
    if (strategy != 'memory_only_ephemeral' && strategy != 'os_secure_store') {
      throw const FormatException(
        'Secure Mesh selected custody strategy is invalid.',
      );
    }
    final restartSemantics = _requiredString(json, 'restartSemantics');
    if (restartSemantics != 're_pair_rekey_after_restart' &&
        restartSemantics != 'persistent_state_available') {
      throw const FormatException(
        'Secure Mesh custody restart semantics are invalid.',
      );
    }
    final enabledHardening = _canonicalCapabilitySet(json, 'enabledHardening');
    if (enabledHardening.isEmpty ||
        enabledHardening.any(
          (capability) =>
              !capability.startsWith('custody.') ||
              !enabled.contains(capability),
        )) {
      throw const FormatException(
        'Secure Mesh enabled custody hardening projection is invalid.',
      );
    }
    final osStoreEnabled = enabled.contains('custody.os_secure_store');
    final expectedStrategy = osStoreEnabled
        ? 'os_secure_store'
        : 'memory_only_ephemeral';
    final expectedRestartSemantics = osStoreEnabled
        ? 'persistent_state_available'
        : 're_pair_rekey_after_restart';
    final expectedHardening = osStoreEnabled
        ? enabled
              .where((capability) => capability.startsWith('custody.'))
              .toSet()
        : const {'custody.memory_only_ephemeral'};
    if (strategy != expectedStrategy ||
        restartSemantics != expectedRestartSemantics ||
        !_sameSet(enabledHardening, expectedHardening)) {
      throw const FormatException(
        'Secure Mesh selected custody projection is inconsistent.',
      );
    }
    return SecureMeshSelectedCustody(
      strategy: strategy,
      restartSemantics: restartSemantics,
      enabledHardening: _orderedByCatalog(enabledHardening),
    );
  }

  final String strategy;
  final String restartSemantics;
  final List<String> enabledHardening;
}

class SecureMeshCapabilityDependency {
  SecureMeshCapabilityDependency({
    required this.capability,
    required List<String> prerequisites,
  }) : prerequisites = List.unmodifiable(prerequisites);

  final String capability;
  final List<String> prerequisites;
}

class SecureMeshCapabilityProjection {
  SecureMeshCapabilityProjection._({
    required this.schemaVersion,
    required this.local,
    required this.peer,
    required List<String> negotiatedProtocolCapabilities,
    required Map<String, String> reasons,
  }) : negotiatedProtocolCapabilities = List.unmodifiable(
         negotiatedProtocolCapabilities,
       ),
       reasons = UnmodifiableMapView(reasons);

  factory SecureMeshCapabilityProjection.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const {
      'schemaVersion',
      'local',
      'peer',
      'negotiatedProtocolCapabilities',
      'reasons',
    }, 'client capability projection');
    final schemaVersion = _requiredInt(json, 'schemaVersion');
    if (schemaVersion != secureMeshCapabilityProjectionSchemaVersion) {
      throw const FormatException(
        'Secure Mesh client capability projection schema is unsupported.',
      );
    }
    final local = SecureMeshCapabilitySetProjection.fromJson(
      _requiredMap(json, 'local'),
    );
    final rawPeer = json['peer'];
    final peer = rawPeer == null
        ? null
        : SecureMeshCapabilitySetProjection.fromJson(
            _asStringMap(rawPeer, 'peer capability projection'),
          );
    final negotiated = _canonicalCapabilitySet(
      json,
      'negotiatedProtocolCapabilities',
    );
    if (negotiated.any((capability) => !capability.startsWith('protocol.'))) {
      throw const FormatException(
        'Secure Mesh negotiated capabilities must be protocol scoped.',
      );
    }
    final reasons = _reasonMap(json, 'reasons');
    _requireLexicalKeyOrder(reasons, 'session capability reasons');
    const allowedSessionReasonKeys = {
      'peer',
      'negotiated_protocol_capabilities',
    };
    if (reasons.keys.any(
      (reason) => !allowedSessionReasonKeys.contains(reason),
    )) {
      throw const FormatException(
        'Secure Mesh session capability reason key is invalid.',
      );
    }
    if (peer == null) {
      if (negotiated.isNotEmpty ||
          !reasons.containsKey('peer') ||
          !reasons.containsKey('negotiated_protocol_capabilities')) {
        throw const FormatException(
          'Secure Mesh inactive session capability projection is inconsistent.',
        );
      }
    } else {
      if (reasons.isNotEmpty) {
        throw const FormatException(
          'Secure Mesh active session capability reasons must be empty.',
        );
      }
      final expectedNegotiated = local.enabled
          .toSet()
          .intersection(peer.enabled.toSet())
          .where((capability) => capability.startsWith('protocol.'));
      if (!_sameSet(negotiated, expectedNegotiated)) {
        throw const FormatException(
          'Secure Mesh negotiated capability projection is not the exact protocol intersection.',
        );
      }
    }
    return SecureMeshCapabilityProjection._(
      schemaVersion: schemaVersion,
      local: local,
      peer: peer,
      negotiatedProtocolCapabilities: _orderedByCatalog(negotiated),
      reasons: _sortedMap(reasons),
    );
  }

  final int schemaVersion;
  final SecureMeshCapabilitySetProjection local;
  final SecureMeshCapabilitySetProjection? peer;
  final List<String> negotiatedProtocolCapabilities;
  final Map<String, String> reasons;
}

void _requireExactKeys(
  Map<String, dynamic> json,
  Set<String> expected,
  String label,
) {
  if (!_sameSet(json.keys, expected)) {
    throw FormatException('Secure Mesh $label fields are invalid.');
  }
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('Secure Mesh $key must be an integer.');
  }
  return value;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('Secure Mesh $key must be a boolean.');
  }
  return value;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Secure Mesh $key must be text.');
  }
  return value;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  return _asStringMap(json[key], key);
}

Map<String, dynamic> _asStringMap(Object? value, String label) {
  if (value is! Map) {
    throw FormatException('Secure Mesh $label must be an object.');
  }
  if (value.keys.any((key) => key is! String)) {
    throw FormatException('Secure Mesh $label contains a non-text field.');
  }
  return Map<String, dynamic>.from(value);
}

Set<String> _canonicalCapabilitySet(Map<String, dynamic> json, String key) {
  final raw = json[key];
  if (raw is! List) {
    throw FormatException('Secure Mesh $key must be an array.');
  }
  final capabilities = <String>{};
  for (final value in raw) {
    if (value is! String || !_capabilityIdPattern.hasMatch(value)) {
      throw FormatException('Secure Mesh $key contains an invalid capability.');
    }
    if (!_canonicalCapabilityCatalog.ids.contains(value)) {
      throw FormatException('Secure Mesh $key contains an unknown capability.');
    }
    if (!capabilities.add(value)) {
      throw FormatException(
        'Secure Mesh $key contains a duplicate capability.',
      );
    }
  }
  final expectedOrder = _orderedByCatalog(capabilities);
  if (!_sameOrderedStrings(raw.cast<String>(), expectedOrder)) {
    throw FormatException(
      'Secure Mesh $key is not in canonical catalog order.',
    );
  }
  return capabilities;
}

Map<String, String> _reasonMap(
  Map<String, dynamic> json,
  String key, {
  bool capabilityKeysOnly = false,
}) {
  final raw = _requiredMap(json, key);
  final reasons = <String, String>{};
  for (final entry in raw.entries) {
    if ((capabilityKeysOnly &&
            (!_capabilityIdPattern.hasMatch(entry.key) ||
                !_canonicalCapabilityCatalog.ids.contains(entry.key))) ||
        entry.value is! String ||
        !_reasonCodePattern.hasMatch(entry.value as String)) {
      throw FormatException('Secure Mesh $key contains an invalid reason.');
    }
    reasons[entry.key] = entry.value as String;
  }
  return reasons;
}

void _requireLexicalKeyOrder(Map<String, String> values, String label) {
  final actual = values.keys.toList(growable: false);
  final expected = actual.toList(growable: false)..sort();
  if (!_sameOrderedStrings(actual, expected)) {
    throw FormatException('Secure Mesh $label are not in stable order.');
  }
}

bool _sameSet(Iterable<String> left, Iterable<String> right) {
  final leftSet = left.toSet();
  final rightSet = right.toSet();
  return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
}

bool _sameOrderedStrings(Iterable<String> left, Iterable<String> right) {
  final leftValues = left.toList(growable: false);
  final rightValues = right.toList(growable: false);
  if (leftValues.length != rightValues.length) {
    return false;
  }
  for (var index = 0; index < leftValues.length; index += 1) {
    if (leftValues[index] != rightValues[index]) {
      return false;
    }
  }
  return true;
}

List<String> _orderedByCatalog(Iterable<String> values) {
  final selected = values.toSet();
  return _canonicalCapabilityCatalog.definitions
      .map((definition) => definition.id)
      .where(selected.contains)
      .toList(growable: false);
}

Map<String, String> _sortedMap(Map<String, String> values) {
  final keys = values.keys.toList(growable: false)..sort();
  return {for (final key in keys) key: values[key]!};
}

class _CanonicalCapabilityCatalog {
  _CanonicalCapabilityCatalog({
    required this.schemaVersion,
    required this.digest,
    required List<_CapabilityDefinition> definitions,
    required Set<String> ids,
  }) : definitions = List.unmodifiable(definitions),
       ids = Set.unmodifiable(ids);

  factory _CanonicalCapabilityCatalog.fromGeneratedSource() {
    if (secureMeshCapabilityCatalogSchemaVersion != 1 ||
        !_sha256DigestPattern.hasMatch(secureMeshCapabilityCatalogDigest)) {
      throw StateError(
        'Canonical Secure Mesh capability catalog binding is invalid.',
      );
    }

    final decoded = jsonDecode(secureMeshCapabilityCatalogSource);
    final catalog = _asStringMap(decoded, 'capability catalog');
    _requireExactKeys(catalog, const {
      'schemaVersion',
      'capabilities',
    }, 'capability catalog');
    final schemaVersion = _requiredInt(catalog, 'schemaVersion');
    if (schemaVersion != secureMeshCapabilityCatalogSchemaVersion) {
      throw StateError(
        'Canonical Secure Mesh capability catalog schema is unsupported.',
      );
    }
    final rawDefinitions = catalog['capabilities'];
    if (rawDefinitions is! List || rawDefinitions.isEmpty) {
      throw StateError('Canonical Secure Mesh capability catalog is empty.');
    }

    final definitions = <_CapabilityDefinition>[];
    final ids = <String>{};
    for (final rawDefinition in rawDefinitions) {
      final definition = _asStringMap(
        rawDefinition,
        'capability catalog definition',
      );
      _requireExactKeys(definition, const {
        'id',
        'scope',
        'mandatory',
        'derived',
        'prerequisites',
      }, 'capability catalog definition');
      final id = _requiredString(definition, 'id');
      if (!_catalogCapabilityIdPattern.hasMatch(id) || !ids.add(id)) {
        throw StateError(
          'Canonical Secure Mesh capability catalog identifier is invalid.',
        );
      }
      final scope = _requiredString(definition, 'scope');
      if (scope != 'protocol_session' && scope != 'local_custody') {
        throw StateError(
          'Canonical Secure Mesh capability catalog scope is invalid.',
        );
      }
      final mandatory = _requiredBool(definition, 'mandatory');
      if (mandatory && scope != 'protocol_session') {
        throw StateError(
          'Canonical Secure Mesh mandatory capability scope is invalid.',
        );
      }
      final derived = _requiredBool(definition, 'derived');
      final rawPrerequisites = definition['prerequisites'];
      if (rawPrerequisites is! List) {
        throw StateError(
          'Canonical Secure Mesh capability prerequisites are invalid.',
        );
      }
      final prerequisites = <String>[];
      final prerequisiteIds = <String>{};
      for (final prerequisite in rawPrerequisites) {
        if (prerequisite is! String ||
            !_catalogCapabilityIdPattern.hasMatch(prerequisite) ||
            prerequisite == id ||
            !prerequisiteIds.add(prerequisite)) {
          throw StateError(
            'Canonical Secure Mesh capability prerequisite is invalid.',
          );
        }
        prerequisites.add(prerequisite);
      }
      definitions.add(
        _CapabilityDefinition(
          id: id,
          mandatory: mandatory,
          derived: derived,
          prerequisites: List.unmodifiable(prerequisites),
        ),
      );
    }

    if (definitions.length != secureMeshCapabilityCatalogCapabilityCount) {
      throw StateError(
        'Canonical Secure Mesh capability catalog is incomplete.',
      );
    }
    final visited = <String>{};
    for (final definition in definitions) {
      if (!definition.prerequisites.every(ids.contains) ||
          !definition.prerequisites.every(visited.contains)) {
        throw StateError(
          'Canonical Secure Mesh capability catalog order is invalid.',
        );
      }
      visited.add(definition.id);
    }
    return _CanonicalCapabilityCatalog(
      schemaVersion: schemaVersion,
      digest: secureMeshCapabilityCatalogDigest,
      definitions: definitions,
      ids: ids,
    );
  }

  final int schemaVersion;
  final String digest;
  final List<_CapabilityDefinition> definitions;
  final Set<String> ids;
}

class _CapabilityDefinition {
  const _CapabilityDefinition({
    required this.id,
    required this.mandatory,
    required this.derived,
    required this.prerequisites,
  });

  final String id;
  final bool mandatory;
  final bool derived;
  final List<String> prerequisites;
}
