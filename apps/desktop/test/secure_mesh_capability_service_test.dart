import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:licoup/src/contracts/generated/secure_mesh_capability_catalog.g.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_capability_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/secure_mesh_capability_projection.dart';

void main() {
  const service = SecureMeshCapabilityService();

  test('generated catalog stays byte-for-byte bound to canonical source', () {
    final source = File(
      '../../crates/licoup-native/resources/'
      'secure-mesh-capability-catalog.json',
    ).readAsStringSync();
    expect(source, secureMeshCapabilityCatalogSource);
    expect(
      sha256.convert(utf8.encode(source)).toString(),
      secureMeshCapabilityCatalogDigest,
    );
    final catalog = jsonDecode(source) as Map<String, dynamic>;
    expect(catalog['schemaVersion'], secureMeshCapabilityCatalogSchemaVersion);
    expect(
      catalog['capabilities'],
      hasLength(secureMeshCapabilityCatalogCapabilityCount),
    );
  });

  test('projects exact native local peer and negotiated protocol sets', () {
    final fixture = activeSecureMeshCapabilityProjectionFixture();
    final projection = service.projectStatus({'capabilityProjection': fixture});
    expect(projection, isNotNull);
    expect(
      projection!.local.enabled,
      (fixture['local']! as Map<String, dynamic>)['enabled'],
    );
    expect(
      projection.peer!.enabled,
      (fixture['peer']! as Map<String, dynamic>)['enabled'],
    );
    expect(
      projection.negotiatedProtocolCapabilities,
      fixture['negotiatedProtocolCapabilities'],
    );
    expect(projection.local.catalogDigest, secureMeshCapabilityCatalogDigest);
    expect(
      projection.local.reasons['custody.os_secure_store'],
      'os_secure_store_not_available',
    );
    expect(
      () => projection.local.enabled.add('protocol.extra'),
      throwsUnsupportedError,
    );
  });

  test('projects truthful local-only native status with redacted reasons', () {
    final fixture = localOnlySecureMeshCapabilityProjectionFixture();
    final projection = service.projectStatus({'capabilityProjection': fixture});
    expect(projection!.peer, isNull);
    expect(projection.negotiatedProtocolCapabilities, isEmpty);
    expect(
      projection.reasons['peer'],
      'secure_mesh_peer_capability_proof_not_available',
    );
  });

  test('rejects fixed posture authorities and non-protocol negotiation', () {
    for (final field in ['tier', 'level', 'ready']) {
      final fixture = activeSecureMeshCapabilityProjectionFixture();
      fixture[field] = 'forbidden';
      expect(
        () => service.projectStatus({'capabilityProjection': fixture}),
        throwsFormatException,
      );
    }

    final nestedTier = activeSecureMeshCapabilityProjectionFixture();
    (nestedTier['local'] as Map<String, dynamic>)['tier'] = 'forbidden';
    expect(
      () => service.projectStatus({'capabilityProjection': nestedTier}),
      throwsFormatException,
    );

    final custodyNegotiation = activeSecureMeshCapabilityProjectionFixture();
    custodyNegotiation['negotiatedProtocolCapabilities'] = [
      'protocol.authenticated_encryption',
      'protocol.complete_aad_binding',
      'custody.memory_only_ephemeral',
    ];
    expect(
      () => service.projectStatus({'capabilityProjection': custodyNegotiation}),
      throwsFormatException,
    );
  });

  test('rejects mismatched intersections and unsafe reason text', () {
    final mismatch = activeSecureMeshCapabilityProjectionFixture();
    mismatch['negotiatedProtocolCapabilities'] = [
      'protocol.authenticated_encryption',
    ];
    expect(
      () => service.projectStatus({'capabilityProjection': mismatch}),
      throwsFormatException,
    );

    final unsafeReason = activeSecureMeshCapabilityProjectionFixture();
    ((unsafeReason['local'] as Map<String, dynamic>)['reasons']
            as Map<String, dynamic>)['custody.os_secure_store'] =
        'private/path leaked';
    expect(
      () => service.projectStatus({'capabilityProjection': unsafeReason}),
      throwsFormatException,
    );
  });

  test(
    'missing projection remains absent while malformed native data fails',
    () {
      expect(service.projectStatus(const {'ok': true}), isNull);
      expect(
        () => service.projectStatus(const {'capabilityProjection': 'invalid'}),
        throwsFormatException,
      );
    },
  );

  test('rejects omitted and unknown canonical catalog nodes', () {
    final omitted = activeSecureMeshCapabilityProjectionFixture();
    final omittedLocal = omitted['local']! as Map<String, dynamic>;
    (omittedLocal['unverified']! as List<dynamic>).remove(
      'custody.secure_enclave',
    );
    expect(
      () => service.projectStatus({'capabilityProjection': omitted}),
      throwsFormatException,
    );

    final unknown = activeSecureMeshCapabilityProjectionFixture();
    final unknownLocal = unknown['local']! as Map<String, dynamic>;
    final unknownNodes = unknownLocal['unverified']! as List<dynamic>;
    unknownNodes[unknownNodes.length - 1] = 'custody.unknown_catalog_node';
    expect(
      () => service.projectStatus({'capabilityProjection': unknown}),
      throwsFormatException,
    );
  });

  test('rejects stale catalog digests and dependency gaps', () {
    final stale = activeSecureMeshCapabilityProjectionFixture();
    (stale['local']! as Map<String, dynamic>)['catalogDigest'] =
        List<String>.filled(64, '0').join();
    expect(
      () => service.projectStatus({'capabilityProjection': stale}),
      throwsFormatException,
    );

    final dependencyGap = activeSecureMeshCapabilityProjectionFixture();
    final local = dependencyGap['local']! as Map<String, dynamic>;
    (local['enabled']! as List<dynamic>).add('custody.software_backed');
    (local['available']! as List<dynamic>).add('custody.software_backed');
    (local['unverified']! as List<dynamic>).remove('custody.software_backed');
    (local['reasons']! as Map<String, dynamic>).remove(
      'custody.software_backed',
    );
    expect(
      () => service.projectStatus({'capabilityProjection': dependencyGap}),
      throwsFormatException,
    );
  });

  test('rejects inconsistent native custody projections', () {
    final wrongStrategy = activeSecureMeshCapabilityProjectionFixture();
    ((wrongStrategy['local']! as Map<String, dynamic>)['custody']!
            as Map<String, dynamic>)['strategy'] =
        'os_secure_store';
    expect(
      () => service.projectStatus({'capabilityProjection': wrongStrategy}),
      throwsFormatException,
    );

    final wrongRestart = activeSecureMeshCapabilityProjectionFixture();
    ((wrongRestart['local']! as Map<String, dynamic>)['custody']!
            as Map<String, dynamic>)['restartSemantics'] =
        'persistent_state_available';
    expect(
      () => service.projectStatus({'capabilityProjection': wrongRestart}),
      throwsFormatException,
    );

    final missingHardening = activeSecureMeshCapabilityProjectionFixture();
    final peerCustody =
        (missingHardening['peer']! as Map<String, dynamic>)['custody']!
            as Map<String, dynamic>;
    (peerCustody['enabledHardening']! as List<dynamic>).remove(
      'custody.os_secure_store',
    );
    expect(
      () => service.projectStatus({'capabilityProjection': missingHardening}),
      throwsFormatException,
    );
  });

  test('rejects incorrect mandatory results and unstable set order', () {
    final mandatoryMismatch = activeSecureMeshCapabilityProjectionFixture();
    final mandatoryLocal = mandatoryMismatch['local']! as Map<String, dynamic>;
    mandatoryLocal['missingMandatory'] = <String>[
      'protocol.authenticated_encryption',
    ];
    mandatoryLocal['mandatoryFoundationComplete'] = false;
    expect(
      () => service.projectStatus({'capabilityProjection': mandatoryMismatch}),
      throwsFormatException,
    );

    final unstable = activeSecureMeshCapabilityProjectionFixture();
    final unstableEnabled =
        ((unstable['local']! as Map<String, dynamic>)['enabled']!
            as List<dynamic>);
    final first = unstableEnabled.removeAt(0);
    unstableEnabled.insert(1, first);
    expect(
      () => service.projectStatus({'capabilityProjection': unstable}),
      throwsFormatException,
    );
  });
}
