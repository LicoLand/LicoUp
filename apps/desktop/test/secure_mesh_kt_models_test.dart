import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const digest =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const authority = SecureMeshKtPinnedAuthority(
    logId: 'configured-log',
    keyId: 'configured-key',
    publicKeyHex: digest,
  );
  const directoryResponse = {
    'claim': {'directoryVersion': 1},
    'inclusion': {'treeSize': 1},
    'latestMap': {'stableLabel': digest},
  };

  test('typed KT requests expose the complete canonical action allowlist', () {
    final requests = <SecureMeshKtRequest>[
      SecureMeshKtRequest.prepareAuthority(
        authority: authority,
        directoryScopeCommitment: digest,
      ),
      SecureMeshKtRequest.publicationRequest(endpointKind: 'desktop_sidecar'),
      SecureMeshKtRequest.revocationRequest(confirmRevocation: true),
      SecureMeshKtRequest.provision(response: directoryResponse),
      SecureMeshKtRequest.gossipSeal(
        gossip: const {'contentType': 'application/vnd.test'},
      ),
      SecureMeshKtRequest.gossipOpen(
        secureEnvelope: const {'ciphertext': 'opaque'},
      ),
      SecureMeshKtRequest.selfMonitor(response: directoryResponse),
      const SecureMeshKtRequest.status(),
    ];

    expect(
      requests.map((request) => request.action.wireName).toSet(),
      SecureMeshKtAction.values.map((action) => action.wireName).toSet(),
    );
    expect(
      requests.where((request) => request.action.requiresAuthorization),
      hasLength(requests.length - 1),
    );
  });

  test('only explicit authority configuration can carry pin or scope', () {
    final prepare = SecureMeshKtRequest.prepareAuthority(
      authority: authority,
      directoryScopeCommitment: digest,
      replaceExistingAuthority: true,
    );
    expect(prepare.params['operation'], 'prepare');
    expect(prepare.params, isNot(contains('confirmAuthorityConfiguration')));
    expect(prepare.params['pin'], isA<Map>());
    expect(prepare.params['directoryScopeCommitment'], digest);
    expect(
      (prepare.params['pin'] as Map)['provenance'],
      'user-configured-external',
    );

    final confirm = SecureMeshKtRequest.confirmAuthority(
      authority: authority,
      directoryScopeCommitment: digest,
      authorityChallengeId: 'foreground-confirmation-challenge',
      confirmAuthorityConfiguration: true,
      replaceExistingAuthority: true,
    );
    expect(confirm.params['operation'], 'confirm');
    expect(confirm.params['authorityChallengeId'], isNotEmpty);
    expect(confirm.params['confirmAuthorityConfiguration'], true);
    expect(confirm.params['allowInteraction'], true);

    final operational = [
      SecureMeshKtRequest.publicationRequest(),
      SecureMeshKtRequest.revocationRequest(confirmRevocation: true),
      SecureMeshKtRequest.provision(response: directoryResponse),
      SecureMeshKtRequest.selfMonitor(response: directoryResponse),
      SecureMeshKtRequest.gossipSeal(gossip: const {'contentType': 'test'}),
      SecureMeshKtRequest.gossipOpen(
        secureEnvelope: const {'ciphertext': 'opaque'},
      ),
      const SecureMeshKtRequest.status(),
    ];
    for (final request in operational) {
      expect(request.params, isNot(contains('pin')));
      expect(request.params, isNot(contains('directoryScopeCommitment')));
      expect(request.params, isNot(contains('authorizationPurpose')));
      expect(request.params, isNot(contains('trustState')));
    }
  });

  test('KT response parser rejects non-redacted key material', () {
    final accepted = SecureMeshKtResponse.fromJson(const {
      'ok': true,
      'privateKeyMaterial': 'redacted',
      'treeSize': 1,
    });
    expect(accepted.value['treeSize'], 1);
    expect(
      () => SecureMeshKtResponse.fromJson(const {
        'ok': true,
        'privateKeyMaterial': 'secret',
      }),
      throwsFormatException,
    );
  });
}
