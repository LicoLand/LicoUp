import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_client/app.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_ios_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS Mobile Relay E2EE uses Keychain-bound runtime secrets', (
    tester,
  ) async {
    const phase = String.fromEnvironment(
      'LICO_IOS_E2E_PHASE',
      defaultValue: 'full',
    );
    const inviteB64 = String.fromEnvironment('LICO_IOS_RELAY_INVITE_B64');
    const mobileDeviceName = String.fromEnvironment(
      'LICO_IOS_MOBILE_DEVICE_NAME',
      defaultValue: 'Lico Arc iOS',
    );
    const timeoutSeconds = int.fromEnvironment(
      'LICO_IOS_RESULT_TIMEOUT_SECONDS',
      defaultValue: 90,
    );

    runApp(const LicoApp());
    await tester.pump(const Duration(milliseconds: 500));

    final bridge = const SecureMeshIosBridge();
    final runtimeStatus = await bridge.status();
    expect(runtimeStatus['ok'], true);
    final nativeRuntime = _map(runtimeStatus['nativeRuntime']);
    final bridgeSecretStore = _map(runtimeStatus['mobileRelaySecretStore']);
    expect(bridgeSecretStore['provider'], 'iOS Keychain');
    expect(bridgeSecretStore['secretStoreBackend'], 'ios-keychain');
    expect(
      bridgeSecretStore['secretStoreContract'],
      'rust_secure_mesh_secret_store_handle_v1',
    );
    expect(bridgeSecretStore.containsKey('rawJsonSecretOverridesUsed'), isTrue);
    expect(bridgeSecretStore['rawJsonSecretOverridesUsed'], isFalse);
    expect(nativeRuntime['ffiBoundary'], 'c-abi');

    if (phase == 'restartProbe') {
      final e2eeAfterRestart = await bridge.nativeJson({
        'action': 'mobile.relay.e2ee.status',
        'params': const {},
      });
      _expectIosE2eeSecretStoreReady(e2eeAfterRestart, 'after app restart');

      final replayProof = await _runIosReplayProof(
        bridge: bridge,
        timeout: Duration(seconds: timeoutSeconds),
        proofLabel: 'ios-restart-replay',
      );
      _expectIosReplayProofReady(replayProof);

      final restartReplay = {
        'iosAppProcessRestarted': true,
        'e2eeStatusAfterRestart': e2eeAfterRestart['ok'] == true,
        'keychainRehydratedAfterRestart': _iosSecretStoreReady(
          e2eeAfterRestart,
        ),
        'commandCreatedAfterRestart': replayProof['commandCreated'] == true,
        'desktopCompletedAfterRestart':
            replayProof['resultEnvelopePresent'] == true,
        ...replayProof,
      };
      _expectIosRestartReplayReady(restartReplay);

      final summary = {
        'ok': true,
        'platform': 'ios',
        'phase': phase,
        'restartReplay': restartReplay,
      };
      final encoded = base64Url.encode(utf8.encode(jsonEncode(summary)));
      // Host verifier parses this sentinel; it intentionally contains no secrets.
      // ignore: avoid_print
      print('LICO_IOS_MOBILE_RELAY_E2E_SUMMARY $encoded');
      return;
    }

    final iosUserPresenceProof = await bridge.nativeJson({
      'action': 'secure_mesh.ios.userPresenceProof',
      'params': const {},
    });
    _expectIosUserPresenceProofReady(iosUserPresenceProof);

    expect(inviteB64.trim(), isNotEmpty);
    final invite = _map(
      jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(inviteB64)))),
    );
    final claimed = await bridge.nativeJson({
      'action': 'mobile.relay.pairing.claim',
      'params': {
        'invite': invite,
        'mobileDeviceName': mobileDeviceName,
        'platform': 'ios',
      },
    });
    expect(claimed['ok'], true);

    final mobileStatus = await bridge.nativeJson({
      'action': 'mobile.relay.pairing.status',
      'params': const {},
    });
    final mobileConfig = _map(mobileStatus['config']);
    final mobileE2ee = _map(mobileConfig['mobileRelayE2ee']);
    expect(mobileConfig['paired'], true);
    expect(mobileE2ee['peerVerified'], true);

    final e2eeAfterClaim = await bridge.nativeJson({
      'action': 'mobile.relay.e2ee.status',
      'params': const {},
    });
    _expectIosE2eeSecretStoreReady(e2eeAfterClaim, 'after claim');

    final created = await bridge.nativeJson({
      'action': 'mobile.relay.commands.createSecure',
      'params': {
        'commandKind': 'client.activity.sync',
        'workspaceId': 'default',
        'body': {
          'limit': 1,
          'iosVerifierCanaryPurpose': 'encrypted relay command body',
        },
      },
    });
    expect(created['ok'], true);
    final commandId = _map(created['command'])['commandId']?.toString() ?? '';
    expect(commandId.trim(), isNotEmpty);

    final result = await _waitForSecureResult(
      bridge: bridge,
      commandId: commandId,
      timeout: Duration(seconds: timeoutSeconds),
    );
    expect(result['ok'], true);
    expect(result['openedResult'], isNotNull);

    final e2eeAfterResult = await bridge.nativeJson({
      'action': 'mobile.relay.e2ee.status',
      'params': const {},
    });
    _expectIosE2eeSecretStoreReady(e2eeAfterResult, 'after result');

    final lifecycle = await _runIosLifecycleChecks(bridge);
    _expectIosLifecycleReady(lifecycle);

    final replayProof = await _runIosReplayProof(
      bridge: bridge,
      timeout: Duration(seconds: timeoutSeconds),
      proofLabel: 'ios-replay',
    );
    _expectIosReplayProofReady(replayProof);
    final iosProductionCallbackAuth = _iosProductionCallbackAuthSummary([
      claimed,
      mobileStatus,
      e2eeAfterClaim,
      created,
      result,
      e2eeAfterResult,
    ]);
    _expectIosProductionCallbackAuthReady(iosProductionCallbackAuth);

    final summary = {
      'ok': true,
      'platform': 'ios',
      'pairing': {
        'claimed': claimed['ok'] == true,
        'mobilePaired': mobileConfig['paired'] == true,
        'mobilePeerVerified': mobileE2ee['peerVerified'] == true,
      },
      'forwarding': {
        'commandCreated': commandId.trim().isNotEmpty,
        'phoneOpenedResult': result['openedResult'] != null,
        'phoneResultStatus':
            _map(_map(result['response'])['command'])['status']?.toString() ??
            '',
        'resultBodyRedacted':
            result['bodyRedacted'] == true ||
            _map(result['openedResult'])['bodyRedacted'] == true,
      },
      'localSecretStorage': _iosSecretStoreSummary(e2eeAfterResult),
      'bridgeSecretStore': {
        'ffiBoundary': nativeRuntime['ffiBoundary']?.toString() ?? '',
        'provider': bridgeSecretStore['provider']?.toString() ?? '',
        'portableConfigRedacted':
            bridgeSecretStore['portableConfigRedacted'] == true,
        'implementationStatus':
            bridgeSecretStore['implementationStatus']?.toString() ?? '',
        'secretStoreContract':
            bridgeSecretStore['secretStoreContract']?.toString() ?? '',
        'secretStoreBackend':
            bridgeSecretStore['secretStoreBackend']?.toString() ?? '',
        'rawJsonSecretOverridesUsedPresent': bridgeSecretStore.containsKey(
          'rawJsonSecretOverridesUsed',
        ),
        'rawJsonSecretOverridesUsed':
            bridgeSecretStore.containsKey('rawJsonSecretOverridesUsed')
            ? bridgeSecretStore['rawJsonSecretOverridesUsed'] == true
            : null,
      },
      'iosUserPresenceProof': _iosUserPresenceProofSummary(
        iosUserPresenceProof,
      ),
      'iosProductionCallbackAuth': iosProductionCallbackAuth,
      'lifecycle': lifecycle,
      'replayProof': replayProof,
    };
    final encoded = base64Url.encode(utf8.encode(jsonEncode(summary)));
    // Host verifier parses this sentinel; it intentionally contains no secrets.
    // ignore: avoid_print
    print('LICO_IOS_MOBILE_RELAY_E2E_SUMMARY $encoded');
  });
}

Future<Map<String, dynamic>> _runIosReplayProof({
  required SecureMeshIosBridge bridge,
  required Duration timeout,
  required String proofLabel,
}) async {
  final created = await bridge.nativeJson({
    'action': 'mobile.relay.commands.createSecure',
    'params': {
      'commandKind': 'client.activity.sync',
      'workspaceId': 'default',
      'body': {'limit': 1, 'proof': proofLabel},
    },
  });
  expect(created['ok'], true);
  final commandId = _map(created['command'])['commandId']?.toString() ?? '';
  expect(commandId.trim(), isNotEmpty);

  final proof = await _waitForResultReplayProof(
    bridge: bridge,
    commandId: commandId,
    timeout: timeout,
  );
  return {
    'commandCreated': commandId.trim().isNotEmpty,
    'resultEnvelopePresent': proof['resultEnvelopePresent'] == true,
    'resultAckPurgeReady': proof['ackPurgeReady'] == true,
    'resultFirstOpenOk': proof['firstOpenOk'] == true,
    'resultFirstOpenBodyRedacted': proof['firstOpenBodyRedacted'] == true,
    'replayRejected': proof['replayRejected'] == true,
    'replayErrorRedacted': proof['replayErrorRedacted'] == true,
    'bodyRedacted': proof['bodyRedacted'] == true,
  };
}

Future<Map<String, dynamic>> _waitForResultReplayProof({
  required SecureMeshIosBridge bridge,
  required String commandId,
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  Map<String, dynamic> last = const {};
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 1));
    last = await bridge.nativeJson({
      'action': 'mobile.relay.commands.resultReplayProof',
      'params': {'commandId': commandId},
    });
    if (last['ok'] == true && last['replayRejected'] == true) {
      return last;
    }
  }
  fail(
    'iOS secure relay replay proof was not available before timeout: '
    '${_safeStatusDetail(last)}',
  );
}

Future<Map<String, dynamic>> _runIosLifecycleChecks(
  SecureMeshIosBridge bridge,
) async {
  const manifest = {
    'fileId': 'ios-lifecycle-file',
    'fileName': 'ios-lifecycle.txt',
    'mimeType': 'text/plain',
    'relativePath': 'ios/lifecycle',
    'totalSize': 16,
    'chunkSize': 8,
    'chunkCount': 2,
  };
  final fileRoute = await bridge.nativeJson({
    'action': 'secure_mesh.file.route',
    'params': const {'manifest': manifest},
  });
  final receiveDestination = await bridge.nativeJson({
    'action': 'secure_mesh.file.receiveDestination',
    'params': const {'manifest': manifest, 'approvedRoot': '/tmp'},
  });
  final localIdentity = _iosLifecycleIdentity('ios-lifecycle-local', 0x44, 1);
  final peerIdentity = _iosLifecycleIdentity('ios-lifecycle-peer', 0x55, 1);
  final replacementPeerIdentity = _iosLifecycleIdentity(
    'ios-lifecycle-peer',
    0x66,
    2,
  );
  final sasPreview = await bridge.nativeJson({
    'action': 'secure_mesh.deviceTrust.verifySas',
    'params': {
      'localIdentity': localIdentity,
      'peerIdentity': peerIdentity,
      'rosterEpoch': 7,
    },
  });
  final sasVerified = await bridge.nativeJson({
    'action': 'secure_mesh.deviceTrust.verifySas',
    'params': {
      'localIdentity': localIdentity,
      'peerIdentity': peerIdentity,
      'rosterEpoch': 7,
      'sas': sasPreview['sas'],
    },
  });
  final qrVerified = await bridge.nativeJson({
    'action': 'secure_mesh.deviceTrust.verifyQr',
    'params': {
      'localIdentity': localIdentity,
      'peerIdentity': peerIdentity,
      'rosterEpoch': 7,
      'qrPayload': sasPreview['qrPayload'],
    },
  });
  final keyChange = await bridge.nativeJson({
    'action': 'secure_mesh.deviceTrust.evaluate',
    'params': {
      'identity': replacementPeerIdentity,
      'previousIdentity': peerIdentity,
      'trustState': 'verified',
    },
  });
  final rotate = await bridge.nativeJson({
    'action': 'secure_mesh.deviceTrust.rotate',
    'params': {'identity': peerIdentity},
  });
  final revoke = await bridge.nativeJson({
    'action': 'secure_mesh.deviceTrust.revoke',
    'params': {'identity': peerIdentity},
  });
  final recover = await bridge.nativeJson({
    'action': 'secure_mesh.deviceTrust.recover',
    'params': {'identity': peerIdentity, 'recoveryConfirmed': false},
  });
  final serviceActionPolicyReady = await _runIosLifecycleServiceActionChecks(
    bridge,
  );
  return {
    'iosAppProcess': true,
    'sharedRustFfiActions': true,
    'fileRouteReady':
        fileRoute['ok'] == true &&
        _map(fileRoute['route'])['metadataEncrypted'] == true &&
        _map(fileRoute['transfer'])['chunkCount'] == 2 &&
        _map(fileRoute['resume'])['ackRequired'] == false,
    'fileReceiveDestinationReady':
        receiveDestination['ok'] == true &&
        _map(receiveDestination['receivePolicy'])['destinationApproved'] ==
            true &&
        _map(receiveDestination['receivePolicy'])['destinationPathRedacted'] ==
            true &&
        _map(receiveDestination['manifest'])['metadataEncrypted'] == true &&
        _map(receiveDestination['manifest'])['bodyRedacted'] == true,
    'sasVerificationReady':
        sasPreview['ok'] == true &&
        sasPreview['observationMatched'] == false &&
        (sasPreview['sas'] as List<dynamic>?)?.length == 12 &&
        sasVerified['ok'] == true &&
        sasVerified['observationMatched'] == true &&
        _map(sasVerified['decision'])['allowedForHighRiskCommand'] == false &&
        _map(sasVerified['decision'])['requiresPersistedTrustRecord'] == true,
    'qrVerificationReady':
        qrVerified['ok'] == true &&
        qrVerified['observationMatched'] == true &&
        _map(qrVerified['decision'])['allowedForHighRiskCommand'] == false &&
        _map(qrVerified['decision'])['requiresPersistedTrustRecord'] == true,
    'keyChangeBlocksSensitive':
        keyChange['ok'] == true &&
        keyChange['keyChangeDetected'] == true &&
        keyChange['trustState'] == 'key_changed' &&
        _map(keyChange['decision'])['allowedForHighRiskCommand'] == false,
    'rotateLifecycleReady':
        rotate['ok'] == true &&
        rotate['lifecycle'] == 'rotate' &&
        rotate['status'] == 'rotation_reverification_required',
    'revokeBlocksSensitive':
        revoke['ok'] == true &&
        revoke['lifecycle'] == 'revoke' &&
        revoke['trustState'] == 'revoked' &&
        _map(revoke['decision'])['allowedForHighRiskCommand'] == false,
    'recoveryRequiresConfirmation':
        recover['ok'] == true &&
        recover['lifecycle'] == 'recover' &&
        recover['status'] == 'recovery_confirmation_required' &&
        _map(recover['decision'])['allowedForHighRiskCommand'] == false,
    'serviceActionPolicyReady': serviceActionPolicyReady,
  };
}

Future<bool> _runIosLifecycleServiceActionChecks(
  SecureMeshIosBridge bridge,
) async {
  const baseScope = {
    'endpointId': 'ios-lifecycle-private-endpoint',
    'conversationId': 'ios-lifecycle-private-conversation',
    'messageId': 'ios-lifecycle-private-message',
    'body': 'ios-lifecycle-private-plaintext-body',
  };
  final fixtures = <Map<String, Object?>>[
    {
      'actionKind': 'message_ttl_set',
      'ttlSeconds': 60,
      'expiresExistingMessages': true,
    },
    {'actionKind': 'message_delete', 'userConfirmed': true},
    {'actionKind': 'screenshot_detected'},
    {
      'actionKind': 'resend_request',
      'missingMessageIds': [
        'ios-lifecycle-private-missing-message-a',
        'ios-lifecycle-private-missing-message-b',
      ],
    },
    {'actionKind': 'typing_state', 'typingState': 'started'},
    {
      'actionKind': 'read_receipt',
      'readUpToMessageId': 'ios-lifecycle-private-read-message',
    },
    {
      'actionKind': 'ack_purge',
      'fileTransferId': 'ios-lifecycle-private-file-transfer',
      'acknowledged': true,
      'transferComplete': true,
    },
  ];
  final outputs = <Map<String, dynamic>>[];
  for (final params in fixtures) {
    outputs.add(
      await bridge.nativeJson({
        'action': 'secure_mesh.lifecycle.serviceAction',
        'params': {...baseScope, ...params},
      }),
    );
  }
  return _lifecycleServiceActionsReady(outputs, 'ios-lifecycle-private');
}

bool _lifecycleServiceActionsReady(
  List<Map<String, dynamic>> outputs,
  String forbiddenPrefix,
) {
  final byKind = {
    for (final output in outputs)
      output['actionKind']?.toString() ?? '': output,
  };
  final ttl = _map(byKind['message_ttl_set']?['servicePolicy']);
  final deleted = _map(byKind['message_delete']?['servicePolicy']);
  final screenshot = _map(byKind['screenshot_detected']?['servicePolicy']);
  final resend = _map(byKind['resend_request']?['servicePolicy']);
  final typing = _map(byKind['typing_state']?['servicePolicy']);
  final readReceipt = _map(byKind['read_receipt']?['servicePolicy']);
  final ack = _map(byKind['ack_purge']?['servicePolicy']);
  final missingDigests = (resend['missingMessageDigests'] as List?) ?? const [];
  final sha256Pattern = RegExp(r'^sha256:[0-9a-f]{64}$');
  return outputs.every(
        (output) =>
            _lifecycleServiceActionEnvelopeReady(output, forbiddenPrefix),
      ) &&
      ttl['ttlSeconds'] == 60 &&
      ttl['localTimerRequired'] == true &&
      ttl['remoteServiceNoticeRequired'] == true &&
      deleted['localDeleteRequired'] == true &&
      deleted['remoteDeleteNoticeRequired'] == true &&
      deleted['purgeLocalCiphertextAfterAck'] == true &&
      screenshot['userVisibleWarningRequired'] == true &&
      screenshot['remoteServiceNoticeRequired'] == true &&
      screenshot['screenshotContentIncluded'] == false &&
      resend['resendRequestRequired'] == true &&
      resend['missingMessageCount'] == 2 &&
      resend['missingMessageIdsRedacted'] == true &&
      missingDigests.length == 2 &&
      missingDigests.every((digest) => sha256Pattern.hasMatch('$digest')) &&
      typing['typingNoticeRequired'] == true &&
      typing['typingStateEncrypted'] == true &&
      typing['typingContentIncluded'] == false &&
      readReceipt['readReceiptRequired'] == true &&
      readReceipt['readMessageIdsRedacted'] == true &&
      sha256Pattern.hasMatch('${readReceipt['readUpToMessageDigest']}') &&
      ack['ackRequired'] == false &&
      ack['purgeLocalCiphertext'] == true &&
      ack['purgeLocalPlaintext'] == true &&
      ack['transferComplete'] == true;
}

bool _lifecycleServiceActionEnvelopeReady(
  Map<String, dynamic> output,
  String forbiddenPrefix,
) {
  final scope = _map(output['scope']);
  final serialized = jsonEncode(output);
  final sha256Pattern = RegExp(r'^sha256:[0-9a-f]{64}$');
  return output['ok'] == true &&
      output['requiresPairwiseOrMlsEnvelope'] == true &&
      output['serverVisiblePlaintextAllowed'] == false &&
      output['metadataRedacted'] == true &&
      output['bodyRedacted'] == true &&
      output['keyMaterial'] == 'redacted' &&
      scope['scopeIdsRedacted'] == true &&
      sha256Pattern.hasMatch('${scope['endpointHash']}') &&
      sha256Pattern.hasMatch('${scope['conversationHash']}') &&
      !serialized.contains(forbiddenPrefix) &&
      !serialized.contains('plaintext-body');
}

Future<Map<String, dynamic>> _waitForSecureResult({
  required SecureMeshIosBridge bridge,
  required String commandId,
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  Map<String, dynamic> last = const {};
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 1));
    last = await bridge.nativeJson({
      'action': 'mobile.relay.commands.resultSecure',
      'params': {'commandId': commandId},
    });
    if (last['ok'] == true && last['openedResult'] != null) {
      return last;
    }
  }
  fail(
    'iOS secure relay result was not available before timeout: '
    '${_safeStatusDetail(last)}',
  );
}

String _safeStatusDetail(Map<String, dynamic> value) {
  final code = value['code']?.toString() ?? '';
  final error = value['error']?.toString() ?? '';
  final detail = [
    code,
    error,
  ].where((item) => item.trim().isNotEmpty).join(': ');
  if (detail.isEmpty) {
    return 'no_result';
  }
  return detail
      .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._~-]+'), 'Bearer [redacted]')
      .replaceAll(
        RegExp(
          r'(pcToken|mobileToken|pairingCode|privateKeyBase64url|signingKeyBase64url|signedPrekeyPrivateKeyBase64url|oneTimePrekeyPrivateKeyBase64url|pairingSecretBase64url|e2eePairingSecret)\s*[:=]\s*"[^"]+"',
          caseSensitive: false,
        ),
        r'$1:[redacted]',
      );
}

void _expectIosE2eeSecretStoreReady(Map<String, dynamic> status, String phase) {
  final store = _map(status['secretStore']);
  expect(status['ok'], true, reason: 'iOS E2EE status failed $phase');
  expect(
    store['allPrivateKeysBoundToPlatform'],
    true,
    reason: 'iOS E2EE private keys are not Keychain-bound $phase',
  );
  expect(store['privateKeyBoundToPlatform'], true);
  expect(store['signingKeyBoundToPlatform'], true);
  expect(store['signedPrekeyPrivateKeyBoundToPlatform'], true);
  expect(store['oneTimePrekeyPrivateKeyBoundToPlatform'], true);
  expect(store['pairingSecretBoundToPlatform'], true);
  expect(store['portableConfigPrivateKeyPresent'], false);
  expect(store['portableConfigSigningKeyPresent'], false);
  expect(store['portableConfigSignedPrekeyPrivateKeyPresent'], false);
  expect(store['portableConfigOneTimePrekeyPrivateKeyPresent'], false);
  expect(store['portableConfigPairingSecretPresent'], false);
}

Map<String, dynamic> _iosSecretStoreSummary(Map<String, dynamic> status) {
  final store = _map(status['secretStore']);
  return {
    'allPrivateKeysBoundToPlatform':
        store['allPrivateKeysBoundToPlatform'] == true,
    'pairingSecretBoundToPlatform':
        store['pairingSecretBoundToPlatform'] == true,
    'portableConfigPrivateMaterialAbsent':
        store['portableConfigPrivateKeyPresent'] == false &&
        store['portableConfigSigningKeyPresent'] == false &&
        store['portableConfigSignedPrekeyPrivateKeyPresent'] == false &&
        store['portableConfigOneTimePrekeyPrivateKeyPresent'] == false,
    'portableConfigPairingSecretAbsent':
        store['portableConfigPairingSecretPresent'] == false,
    'persistentBackend': store['persistentBackend']?.toString() ?? '',
  };
}

Map<String, dynamic> _iosUserPresenceProofSummary(Map<String, dynamic> proof) {
  return {
    'ok': proof['ok'] == true,
    'localAuthenticationAvailable':
        proof['localAuthenticationAvailable'] == true,
    'userPresencePromptStarted': proof['userPresencePromptStarted'] == true,
    'authenticated': proof['authenticated'] == true,
    'secretReadAfterUserPresence': proof['secretReadAfterUserPresence'] == true,
    'credentialEntrySurface': proof['credentialEntrySurface']?.toString() ?? '',
    'systemPromptSurface': proof['systemPromptSurface']?.toString() ?? '',
    'physicalUserPresenceRequired':
        proof['physicalUserPresenceRequired'] == true,
    'systemCredentialPromptAvailable':
        proof['systemCredentialPromptAvailable'] == true,
    'systemCredentialPromptStarted':
        proof['systemCredentialPromptStarted'] == true,
    'systemCredentialPromptCompleted':
        proof['systemCredentialPromptCompleted'] == true,
    'systemCredentialPromptResult':
        proof['systemCredentialPromptResult']?.toString() ?? '',
    'accessControl': proof['accessControl']?.toString() ?? '',
    'accessibility': proof['accessibility']?.toString() ?? '',
    'keychainUserPresencePolicyReady':
        proof['keychainUserPresencePolicyReady'] == true,
    'nonInteractiveReadBlocked': proof['nonInteractiveReadBlocked'] == true,
    'failClosedWhenInteractionNotAllowed':
        proof['failClosedWhenInteractionNotAllowed'] == true,
    'failClosedOnUserCancel': proof['failClosedOnUserCancel'] == true,
    'failClosedOnAuthFailed': proof['failClosedOnAuthFailed'] == true,
    'cancelOrAuthFailureProbeRequiredForProduction':
        proof['cancelOrAuthFailureProbeRequiredForProduction'] == true,
    'cancelOrAuthFailureProbeReady':
        proof['cancelOrAuthFailureProbeReady'] == true,
    'appPasswordPromptUsed': proof['appPasswordPromptUsed'] == true,
    'appCredentialPromptUsed': proof['appCredentialPromptUsed'] == true,
    'biometricDataHandledByApp': proof['biometricDataHandledByApp'] == true,
    'keyMaterialExported': proof['keyMaterialExported'] == true,
    'rawSecretMaterialIncluded': proof['rawSecretMaterialIncluded'] == true,
  };
}

Map<String, dynamic> _iosProductionCallbackAuthSummary(
  List<Map<String, dynamic>> responses,
) {
  final reports = responses
      .map((response) => _map(response['iosProductionCallbackAuth']))
      .where((report) => report.isNotEmpty)
      .toList(growable: false);
  final preDispatchSecretReadCount = reports.fold<int>(
    0,
    (sum, report) => sum + _intValue(report['preDispatchSecretReadCount']),
  );
  final preDispatchSecretReadWithAuthenticationContextCount = reports.fold<int>(
    0,
    (sum, report) =>
        sum +
        _intValue(
          report['preDispatchSecretReadWithAuthenticationContextCount'],
        ),
  );
  final callbackSecretReadCount = reports.fold<int>(
    0,
    (sum, report) => sum + _intValue(report['callbackSecretReadCount']),
  );
  final callbackSecretReadWithAuthenticationContextCount = reports.fold<int>(
    0,
    (sum, report) =>
        sum +
        _intValue(report['callbackSecretReadWithAuthenticationContextCount']),
  );
  final callbackSecretWriteCount = reports.fold<int>(
    0,
    (sum, report) => sum + _intValue(report['callbackSecretWriteCount']),
  );
  final callbackSecretDeleteCount = reports.fold<int>(
    0,
    (sum, report) => sum + _intValue(report['callbackSecretDeleteCount']),
  );
  final preDispatchSecretWriteCount = reports.fold<int>(
    0,
    (sum, report) => sum + _intValue(report['preDispatchSecretWriteCount']),
  );
  final preDispatchSecretWriteWithAuthenticationContextCount = reports
      .fold<int>(
        0,
        (sum, report) =>
            sum +
            _intValue(
              report['preDispatchSecretWriteWithAuthenticationContextCount'],
            ),
      );
  final preDispatchSecretDeleteCount = reports.fold<int>(
    0,
    (sum, report) => sum + _intValue(report['preDispatchSecretDeleteCount']),
  );
  final preDispatchSecretDeleteWithAuthenticationContextCount = reports
      .fold<int>(
        0,
        (sum, report) =>
            sum +
            _intValue(
              report['preDispatchSecretDeleteWithAuthenticationContextCount'],
            ),
      );
  final callbackSecretWriteWithAuthenticationContextCount = reports.fold<int>(
    0,
    (sum, report) =>
        sum +
        _intValue(report['callbackSecretWriteWithAuthenticationContextCount']),
  );
  final callbackSecretDeleteWithAuthenticationContextCount = reports.fold<int>(
    0,
    (sum, report) =>
        sum +
        _intValue(report['callbackSecretDeleteWithAuthenticationContextCount']),
  );
  final authorizationBatchOperationCount = reports.fold<int>(
    0,
    (sum, report) =>
        sum + _intValue(report['authorizationBatchOperationCount']),
  );
  final authorizationBatchConsumedOperationCount = reports.fold<int>(
    0,
    (sum, report) =>
        sum + _intValue(report['authorizationBatchConsumedOperationCount']),
  );
  final authorizationBatchRemainingOperationCount = reports.fold<int>(
    0,
    (sum, report) =>
        sum + _intValue(report['authorizationBatchRemainingOperationCount']),
  );
  final authContextCreated =
      reports.isNotEmpty &&
      reports.every(
        (report) => report['iosCallbackAuthContextCreated'] == true,
      );
  final callbackReadsUseAuthenticationContext =
      callbackSecretReadCount > 0 &&
      callbackSecretReadWithAuthenticationContextCount ==
          callbackSecretReadCount;
  final callbackReadsUseSharedLAContext =
      callbackReadsUseAuthenticationContext &&
      reports.any(
        (report) => report['iosCallbackReadsUseSharedLAContext'] == true,
      );
  final preDispatchSecretReadsUseAuthenticationContext =
      preDispatchSecretReadWithAuthenticationContextCount ==
      preDispatchSecretReadCount;
  final totalReadCount = preDispatchSecretReadCount + callbackSecretReadCount;
  final attachedReadCount =
      preDispatchSecretReadWithAuthenticationContextCount +
      callbackSecretReadWithAuthenticationContextCount;
  final authContextAttachedToAllReads =
      totalReadCount > 0 && attachedReadCount == totalReadCount;
  final totalOperationCount =
      preDispatchSecretReadCount +
      preDispatchSecretWriteCount +
      preDispatchSecretDeleteCount +
      callbackSecretReadCount +
      callbackSecretWriteCount +
      callbackSecretDeleteCount;
  final attachedOperationCount =
      preDispatchSecretReadWithAuthenticationContextCount +
      preDispatchSecretWriteWithAuthenticationContextCount +
      preDispatchSecretDeleteWithAuthenticationContextCount +
      callbackSecretReadWithAuthenticationContextCount +
      callbackSecretWriteWithAuthenticationContextCount +
      callbackSecretDeleteWithAuthenticationContextCount;
  final authContextAttachedToAllOperations =
      totalOperationCount > 0 &&
      attachedOperationCount == totalOperationCount &&
      reports.every(
        (report) =>
            report['iosCallbackAuthContextAttachedToAllOperations'] == true,
      );
  final sharedSystemAuthorizationContextRequired =
      reports.isNotEmpty &&
      reports.every(
        (report) => report['sharedSystemAuthorizationContextRequired'] == true,
      );
  final sharedSystemAuthorizationContextAvailable =
      reports.isNotEmpty &&
      reports.every(
        (report) => report['sharedSystemAuthorizationContextAvailable'] == true,
      );
  final systemAuthorizationAttemptCount =
      reports.isNotEmpty &&
          reports.every(
            (report) =>
                _intValue(report['systemAuthorizationAttemptCount']) == 1,
          )
      ? 1
      : 0;
  final systemAuthorizationCompleted =
      reports.isNotEmpty &&
      reports.every((report) => report['systemAuthorizationCompleted'] == true);
  final authorizationBatchPromptBudgetReady =
      reports.isNotEmpty &&
      reports.every(
        (report) => report['authorizationBatchPromptBudgetReady'] == true,
      );
  final authorizationBatchWithinBudget =
      reports.isNotEmpty &&
      reports.every(
        (report) => report['authorizationBatchWithinBudget'] == true,
      ) &&
      authorizationBatchOperationCount > 0 &&
      authorizationBatchConsumedOperationCount > 0 &&
      authorizationBatchConsumedOperationCount <=
          authorizationBatchOperationCount &&
      authorizationBatchRemainingOperationCount ==
          authorizationBatchOperationCount -
              authorizationBatchConsumedOperationCount;
  final allowableReuseDurationSeconds = reports.fold<int>(0, (
    maxValue,
    report,
  ) {
    final value = _intValue(report['allowableReuseDurationSeconds']);
    return value > maxValue ? value : maxValue;
  });
  final authenticationReuseWindowConfigured =
      reports.isNotEmpty &&
      reports.every(
        (report) =>
            report['authenticationReuseWindowConfigured'] == true &&
            _intValue(report['allowableReuseDurationSeconds']) > 0 &&
            _intValue(report['allowableReuseDurationSeconds']) <= 300,
      );
  final appPasswordPromptUsedPresent =
      reports.isNotEmpty &&
      reports.every((report) => report.containsKey('appPasswordPromptUsed'));
  final appCredentialPromptUsedPresent =
      reports.isNotEmpty &&
      reports.every((report) => report.containsKey('appCredentialPromptUsed'));
  final keyMaterialExportedPresent =
      reports.isNotEmpty &&
      reports.every((report) => report.containsKey('keyMaterialExported'));
  final rawSecretMaterialIncludedPresent =
      reports.isNotEmpty &&
      reports.every(
        (report) => report.containsKey('rawSecretMaterialIncluded'),
      );
  final localizedErrorsIncludedPresent =
      reports.isNotEmpty &&
      reports.every((report) => report.containsKey('localizedErrorsIncluded'));
  final appPasswordPromptUsed = reports.any(
    (report) => report['appPasswordPromptUsed'] == true,
  );
  final appCredentialPromptUsed = reports.any(
    (report) => report['appCredentialPromptUsed'] == true,
  );
  final biometricDataHandledByApp = reports.any(
    (report) => report['biometricDataHandledByApp'] == true,
  );
  final keyMaterialExported = reports.any(
    (report) => report['keyMaterialExported'] == true,
  );
  final rawSecretMaterialIncluded = reports.any(
    (report) => report['rawSecretMaterialIncluded'] == true,
  );
  final localizedErrorsIncluded = reports.any(
    (report) => report['localizedErrorsIncluded'] == true,
  );
  final singleSystemAuthorizationContextVerified =
      authContextCreated &&
      callbackReadsUseSharedLAContext &&
      preDispatchSecretReadsUseAuthenticationContext &&
      authContextAttachedToAllOperations &&
      sharedSystemAuthorizationContextRequired &&
      sharedSystemAuthorizationContextAvailable &&
      systemAuthorizationAttemptCount == 1 &&
      systemAuthorizationCompleted;
  final ready =
      singleSystemAuthorizationContextVerified &&
      authorizationBatchPromptBudgetReady &&
      authorizationBatchWithinBudget &&
      authenticationReuseWindowConfigured &&
      appPasswordPromptUsedPresent &&
      appCredentialPromptUsedPresent &&
      keyMaterialExportedPresent &&
      rawSecretMaterialIncludedPresent &&
      localizedErrorsIncludedPresent &&
      !appPasswordPromptUsed &&
      !appCredentialPromptUsed &&
      !biometricDataHandledByApp &&
      !keyMaterialExported &&
      !rawSecretMaterialIncluded &&
      !localizedErrorsIncluded;
  return {
    'iosProductionCallbackAuthReady': ready,
    'iosCallbackAuthContextCreated': authContextCreated,
    'iosCallbackReadsUseAuthenticationContext':
        callbackReadsUseAuthenticationContext,
    'iosCallbackReadsUseSharedLAContext': callbackReadsUseSharedLAContext,
    'iosSingleSystemAuthorizationContextVerified':
        singleSystemAuthorizationContextVerified,
    'iosPreDispatchSecretReadsUseAuthenticationContext':
        preDispatchSecretReadsUseAuthenticationContext,
    'iosCallbackAuthContextAttachedToAllReads': authContextAttachedToAllReads,
    'iosCallbackAuthContextAttachedToAllOperations':
        authContextAttachedToAllOperations,
    'sharedSystemAuthorizationContextRequired':
        sharedSystemAuthorizationContextRequired,
    'sharedSystemAuthorizationContextAvailable':
        sharedSystemAuthorizationContextAvailable,
    'systemAuthorizationAttemptCount': systemAuthorizationAttemptCount,
    'systemAuthorizationCompleted': systemAuthorizationCompleted,
    'authorizationBatchPromptBudgetReady': authorizationBatchPromptBudgetReady,
    'authorizationBatchOperationCount': authorizationBatchOperationCount,
    'authorizationBatchConsumedOperationCount':
        authorizationBatchConsumedOperationCount,
    'authorizationBatchRemainingOperationCount':
        authorizationBatchRemainingOperationCount,
    'authorizationBatchWithinBudget': authorizationBatchWithinBudget,
    'allowableReuseDurationSeconds': allowableReuseDurationSeconds,
    'authenticationReuseWindowConfigured': authenticationReuseWindowConfigured,
    'preDispatchSecretReadCount': preDispatchSecretReadCount,
    'preDispatchSecretReadWithAuthenticationContextCount':
        preDispatchSecretReadWithAuthenticationContextCount,
    'preDispatchSecretWriteCount': preDispatchSecretWriteCount,
    'preDispatchSecretWriteWithAuthenticationContextCount':
        preDispatchSecretWriteWithAuthenticationContextCount,
    'preDispatchSecretDeleteCount': preDispatchSecretDeleteCount,
    'preDispatchSecretDeleteWithAuthenticationContextCount':
        preDispatchSecretDeleteWithAuthenticationContextCount,
    'callbackSecretReadCount': callbackSecretReadCount,
    'callbackSecretReadWithAuthenticationContextCount':
        callbackSecretReadWithAuthenticationContextCount,
    'callbackSecretWriteCount': callbackSecretWriteCount,
    'callbackSecretWriteWithAuthenticationContextCount':
        callbackSecretWriteWithAuthenticationContextCount,
    'callbackSecretDeleteCount': callbackSecretDeleteCount,
    'callbackSecretDeleteWithAuthenticationContextCount':
        callbackSecretDeleteWithAuthenticationContextCount,
    'credentialEntrySurface': 'ios_system_local_auth_prompt',
    'systemPromptSurface': 'ios_system_local_auth_prompt',
    'appPasswordPromptUsedPresent': appPasswordPromptUsedPresent,
    'appPasswordPromptUsed': appPasswordPromptUsed,
    'appCredentialPromptUsedPresent': appCredentialPromptUsedPresent,
    'appCredentialPromptUsed': appCredentialPromptUsed,
    'biometricDataHandledByApp': biometricDataHandledByApp,
    'keyMaterialExportedPresent': keyMaterialExportedPresent,
    'keyMaterialExported': keyMaterialExported,
    'rawSecretMaterialIncludedPresent': rawSecretMaterialIncludedPresent,
    'rawSecretMaterialIncluded': rawSecretMaterialIncluded,
    'localizedErrorsIncludedPresent': localizedErrorsIncludedPresent,
    'localizedErrorsIncluded': localizedErrorsIncluded,
  };
}

void _expectIosUserPresenceProofReady(Map<String, dynamic> proof) {
  expect(proof['ok'], true);
  expect(proof['localAuthenticationAvailable'], true);
  expect(proof['userPresencePromptStarted'], true);
  expect(proof['authenticated'], true);
  expect(proof['secretReadAfterUserPresence'], true);
  expect(proof['credentialEntrySurface'], 'ios_system_local_auth_prompt');
  expect(proof['systemPromptSurface'], 'ios_system_local_auth_prompt');
  expect(proof['physicalUserPresenceRequired'], true);
  expect(proof['systemCredentialPromptAvailable'], true);
  expect(proof['systemCredentialPromptStarted'], true);
  expect(proof['systemCredentialPromptCompleted'], true);
  expect(proof['systemCredentialPromptResult'], 'authenticated');
  expect(proof['accessControl'], 'userPresence');
  expect(proof['accessibility'], 'WhenUnlockedThisDeviceOnly');
  expect(proof['keychainUserPresencePolicyReady'], true);
  expect(proof['nonInteractiveReadBlocked'], true);
  expect(proof['failClosedWhenInteractionNotAllowed'], true);
  expect(proof['appPasswordPromptUsed'], false);
  expect(proof['appCredentialPromptUsed'], false);
  expect(proof['biometricDataHandledByApp'], false);
  expect(proof['keyMaterialExported'], false);
  expect(proof['rawSecretMaterialIncluded'], false);
}

void _expectIosProductionCallbackAuthReady(Map<String, dynamic> proof) {
  expect(proof['iosProductionCallbackAuthReady'], true);
  expect(proof['iosCallbackAuthContextCreated'], true);
  expect(proof['iosCallbackReadsUseAuthenticationContext'], true);
  expect(proof['iosCallbackReadsUseSharedLAContext'], true);
  expect(proof['iosSingleSystemAuthorizationContextVerified'], true);
  expect(proof['iosPreDispatchSecretReadsUseAuthenticationContext'], true);
  expect(proof['iosCallbackAuthContextAttachedToAllReads'], true);
  expect(proof['iosCallbackAuthContextAttachedToAllOperations'], true);
  expect(proof['sharedSystemAuthorizationContextRequired'], true);
  expect(proof['sharedSystemAuthorizationContextAvailable'], true);
  expect(proof['systemAuthorizationAttemptCount'], 1);
  expect(proof['systemAuthorizationCompleted'], true);
  expect(proof['authorizationBatchPromptBudgetReady'], true);
  expect(proof['authorizationBatchWithinBudget'], true);
  expect(_intValue(proof['authorizationBatchOperationCount']) > 0, true);
  expect(
    _intValue(proof['authorizationBatchConsumedOperationCount']) > 0,
    true,
  );
  expect(
    proof['authorizationBatchRemainingOperationCount'],
    _intValue(proof['authorizationBatchOperationCount']) -
        _intValue(proof['authorizationBatchConsumedOperationCount']),
  );
  expect(_intValue(proof['allowableReuseDurationSeconds']) > 0, true);
  expect(_intValue(proof['allowableReuseDurationSeconds']) <= 300, true);
  expect(proof['authenticationReuseWindowConfigured'], true);
  expect(_intValue(proof['callbackSecretReadCount']) > 0, true);
  expect(
    proof['callbackSecretReadWithAuthenticationContextCount'],
    proof['callbackSecretReadCount'],
  );
  expect(
    proof['preDispatchSecretWriteWithAuthenticationContextCount'],
    proof['preDispatchSecretWriteCount'],
  );
  expect(
    proof['preDispatchSecretDeleteWithAuthenticationContextCount'],
    proof['preDispatchSecretDeleteCount'],
  );
  expect(
    proof['callbackSecretWriteWithAuthenticationContextCount'],
    proof['callbackSecretWriteCount'],
  );
  expect(
    proof['callbackSecretDeleteWithAuthenticationContextCount'],
    proof['callbackSecretDeleteCount'],
  );
  expect(proof['appPasswordPromptUsedPresent'], true);
  expect(proof['appPasswordPromptUsed'], false);
  expect(proof['appCredentialPromptUsedPresent'], true);
  expect(proof['appCredentialPromptUsed'], false);
  expect(proof['keyMaterialExportedPresent'], true);
  expect(proof['keyMaterialExported'], false);
  expect(proof['rawSecretMaterialIncludedPresent'], true);
  expect(proof['rawSecretMaterialIncluded'], false);
  expect(proof['localizedErrorsIncludedPresent'], true);
  expect(proof['localizedErrorsIncluded'], false);
}

bool _iosSecretStoreReady(Map<String, dynamic> status) {
  final summary = _iosSecretStoreSummary(status);
  return summary['allPrivateKeysBoundToPlatform'] == true &&
      summary['pairingSecretBoundToPlatform'] == true &&
      summary['portableConfigPrivateMaterialAbsent'] == true &&
      summary['portableConfigPairingSecretAbsent'] == true &&
      summary['persistentBackend'].toString().contains('ios_keychain');
}

int _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

Map<String, dynamic> _iosLifecycleIdentity(
  String endpointId,
  int byte,
  int rotationEpoch,
) {
  return {
    'endpointId': endpointId,
    'identityPublicKey': _repeatedHex(byte),
    'signingPublicKey': _repeatedHex(byte + 1),
    'rotationEpoch': rotationEpoch,
  };
}

String _repeatedHex(int byte) {
  return List<String>.filled(
    32,
    (byte & 0xff).toRadixString(16).padLeft(2, '0'),
  ).join(':');
}

void _expectIosLifecycleReady(Map<String, dynamic> lifecycle) {
  expect(lifecycle['iosAppProcess'], true);
  expect(lifecycle['sharedRustFfiActions'], true);
  expect(lifecycle['fileRouteReady'], true);
  expect(lifecycle['fileReceiveDestinationReady'], true);
  expect(lifecycle['sasVerificationReady'], true);
  expect(lifecycle['qrVerificationReady'], true);
  expect(lifecycle['keyChangeBlocksSensitive'], true);
  expect(lifecycle['rotateLifecycleReady'], true);
  expect(lifecycle['revokeBlocksSensitive'], true);
  expect(lifecycle['recoveryRequiresConfirmation'], true);
  expect(lifecycle['serviceActionPolicyReady'], true);
}

void _expectIosReplayProofReady(Map<String, dynamic> replayProof) {
  expect(replayProof['commandCreated'], true);
  expect(replayProof['resultEnvelopePresent'], true);
  expect(replayProof['resultAckPurgeReady'], true);
  expect(replayProof['resultFirstOpenOk'], true);
  expect(replayProof['resultFirstOpenBodyRedacted'], true);
  expect(replayProof['replayRejected'], true);
  expect(replayProof['replayErrorRedacted'], true);
  expect(replayProof['bodyRedacted'], true);
}

void _expectIosRestartReplayReady(Map<String, dynamic> restartReplay) {
  expect(restartReplay['iosAppProcessRestarted'], true);
  expect(restartReplay['e2eeStatusAfterRestart'], true);
  expect(restartReplay['keychainRehydratedAfterRestart'], true);
  expect(restartReplay['commandCreatedAfterRestart'], true);
  expect(restartReplay['desktopCompletedAfterRestart'], true);
  _expectIosReplayProofReady(restartReplay);
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, nested) => MapEntry(key.toString(), nested));
  }
  return <String, dynamic>{};
}
