import 'package:flutter_client/src/contracts/secure_mesh_mls_models.dart';
import 'package:flutter_test/flutter_test.dart';

var _synthSeq = 0;
String _synth(String label) => '$label-${_synthSeq++}';

final sv_a2v5lxbhy2thz2u = _synth('a2V5LXBhY2thZ2U');

void main() {
  final sv_identity_public_bob = _synth('identity-public-bob');
  final sv_signing_public = _synth('signing-public');
  final sv_identity_public = _synth('identity-public');
  final sv_signing_public_bob = _synth('signing-public-bob');
  final alice = SecureMeshMlsPublicIdentity(
    endpointId: 'desktop_gui:alice',
    identityPublicKeyBase64url: sv_identity_public,
    signingPublicKeyBase64url: sv_signing_public,
    rotationEpoch: 1,
  );
  final bob = SecureMeshMlsPublicIdentity(
    endpointId: 'mobile:bob',
    identityPublicKeyBase64url: sv_identity_public_bob,
    signingPublicKeyBase64url: sv_signing_public_bob,
    rotationEpoch: 2,
  );
  const context = SecureMeshMlsContentContext(
    envelopeId: 'env-1',
    messageId: 'msg-1',
    opaqueMailboxId: 'mailbox-1',
    senderEndpointId: 'desktop_gui:alice',
    recipientEndpointId: 'mobile:bob',
    sessionId: 'mls-session-1',
    createdAt: '2026-07-12T00:00:00Z',
    expiresAt: '2026-07-12T00:10:00Z',
  );
  const roster = [
    SecureMeshMlsTrustedIdentity(identity: alice),
    SecureMeshMlsTrustedIdentity(identity: bob),
  ];

  test('typed MLS requests expose only the product action allowlist', () {
    final requests = <SecureMeshMlsRequest>[
      const SecureMeshMlsRequest.status(),
      SecureMeshMlsRequest.participantEnsure(),
      SecureMeshMlsRequest.keyPackageCreate(),
      SecureMeshMlsRequest.groupCreate(groupIdBase64url: 'Z3JvdXA'),
      SecureMeshMlsRequest.memberAdd(
        groupIdBase64url: 'Z3JvdXA',
        memberKeyPackageId: 'kp-1',
        memberKeyPackageBase64url: sv_a2v5lxbhy2thz2u,
        memberIdentity: bob,
        memberCapabilityProof: const {
          'claims': {'schemaVersion': 1},
          'signature': 'signature',
        },
        memberDirectoryVersion: 7,
        memberKeyPackageVersion: 3,
        untrustedDirectoryResponse: const {
          'claim': {'directoryVersion': 7},
          'inclusion': {'treeSize': 1},
          'latestMap': {'stableLabel': 'label'},
        },
      ),
      SecureMeshMlsRequest.memberRemove(
        groupIdBase64url: 'Z3JvdXA',
        expectedEpoch: 8,
        memberIdentity: bob,
      ),
      SecureMeshMlsRequest.groupJoin(
        groupIdBase64url: 'Z3JvdXA',
        inviterIdentity: alice,
        expectedRosterEndpointIds: const ['desktop_gui:alice', 'mobile:bob'],
        trustedRoster: roster,
        welcomeMessageBase64url: 'd2VsY29tZQ',
      ),
      SecureMeshMlsRequest.commitProcess(
        groupIdBase64url: 'Z3JvdXA',
        committerIdentity: alice,
        addedMemberIdentity: bob,
        trustedRoster: roster,
        commitMessageBase64url: 'Y29tbWl0',
      ),
      SecureMeshMlsRequest.payloadSeal(
        groupIdBase64url: 'Z3JvdXA',
        trustedRoster: roster,
        context: context,
        payloadKind: 'command',
        bodyBase64url: 'cGluZw',
      ),
      SecureMeshMlsRequest.payloadOpen(
        groupIdBase64url: 'Z3JvdXA',
        trustedSenderIdentity: alice,
        trustedRoster: roster,
        context: context,
        expectedPayloadKind: 'command',
        messageBase64url: 'bWxzLW1lc3NhZ2U',
      ),
    ];

    expect(
      requests.map((request) => request.action.wireName).toSet(),
      SecureMeshMlsAction.values.map((action) => action.wireName).toSet(),
    );
    expect(
      requests.where((request) => request.action.requiresAuthorization),
      hasLength(requests.length - 1),
    );
    expect(requests.last.params['trustedRoster'], hasLength(2));
    expect(
      requests.expand((request) => request.params.keys),
      isNot(contains('trustState')),
    );
    expect(
      requests.last.params['trustedRoster'].toString(),
      isNot(contains('trustState')),
    );
    expect(requests.last.params, isNot(contains('privateKeyMaterial')));
    final memberAdd = requests.firstWhere(
      (request) => request.action == SecureMeshMlsAction.memberAdd,
    );
    expect(memberAdd.params['memberDirectoryVersion'], 7);
    expect(memberAdd.params['memberKeyPackageVersion'], 3);
    expect(memberAdd.params['untrustedDirectoryResponse'], isA<Map>());
    final memberRemove = requests.firstWhere(
      (request) => request.action == SecureMeshMlsAction.memberRemove,
    );
    expect(memberRemove.params, {
      'groupIdBase64url': 'Z3JvdXA',
      'expectedEpoch': 8,
      'memberIdentity': bob.toJson(),
      'allowInteraction': true,
    });
  });

  test('MLS epochs and member-add versions use JSON safe integers', () {
    expect(
      () => SecureMeshMlsRequest.memberAdd(
        groupIdBase64url: 'Z3JvdXA',
        memberKeyPackageId: 'kp-1',
        memberKeyPackageBase64url: sv_a2v5lxbhy2thz2u,
        memberIdentity: bob,
        memberCapabilityProof: const {'proof': true},
        memberDirectoryVersion: 9007199254740992,
        memberKeyPackageVersion: 1,
        untrustedDirectoryResponse: const {'claim': {}},
      ),
      throwsFormatException,
    );
    expect(
      () => SecureMeshMlsRequest.memberRemove(
        groupIdBase64url: 'Z3JvdXA',
        expectedEpoch: 9007199254740992,
        memberIdentity: bob,
      ),
      throwsFormatException,
    );
  });

  test('MLS response parser rejects any non-redacted key material', () {
  final sv_secret = _synth('secret');
    final accepted = SecureMeshMlsResponse.fromJson(const {
      'ok': true,
      'privateKeyMaterial': 'redacted',
      'epoch': 1,
    });
    expect(accepted.value['epoch'], 1);

    expect(
      () => SecureMeshMlsResponse.fromJson( {
        'ok': true,
        'privateKeyMaterial': sv_secret,
      }),
      throwsFormatException,
    );
    expect(
      () => SecureMeshMlsResponse.fromJson(const {'ok': false}),
      throwsFormatException,
    );
  });
}
