import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:licoup/app.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_ios_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _sentinel = 'LICO_MOBILE_SIMULATOR_CLOSURE_SUMMARY ';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile simulator closes build, FFI, and simulated auth', (
    tester,
  ) async {
    expect(Platform.isAndroid || Platform.isIOS, true);

    runApp(const LicoApp());
    await tester.pump(const Duration(milliseconds: 750));

    final platform = Platform.isAndroid ? 'android' : 'ios';
    final SecureMeshMobileBridge bridge = Platform.isAndroid
        ? const SecureMeshAndroidBridge()
        : const SecureMeshIosBridge();
    final status = await bridge.status();
    final nativeRuntime = _map(status['nativeRuntime']);
    final channel = _map(status['bridge']);

    expect(status['ok'], true);
    expect(status['platform'], platform);
    expect(channel['statusMethod'], true);
    expect(channel['writeRuntimeStatusMethod'], true);
    expect(channel['nativeJsonMethod'], true);
    expect(nativeRuntime['provider'], 'licoup-native');
    expect(nativeRuntime['loaded'], true);
    expect(nativeRuntime['selfTestPassed'], true);
    expect(nativeRuntime['usesSharedRustCore'], true);
    expect(nativeRuntime['ffiBoundary'], Platform.isAndroid ? 'jni' : 'c-abi');

    final authorization = Platform.isAndroid
        ? await bridge.nativeJson({
            'action': 'secure_mesh.android.userAuthentication.request',
            'params': const {
              'waitForCompletion': true,
              'timeoutSeconds': 45,
              'forcePrompt': true,
            },
          })
        : await bridge.nativeJson({
            'action': 'secure_mesh.ios.userPresenceProof',
            'params': const {},
          });
    _expectSimulatedAuthorizationReady(platform, authorization);

    final runtimeWrite = await bridge.writeRuntimeStatus();
    expect(runtimeWrite['ok'], true);
    expect(runtimeWrite['writtenByAppProcess'], true);

    final summary = {
      'ok': true,
      'platform': platform,
      'bridgeReady': true,
      'nativeFfiReady': true,
      'runtimeStatusWritten': true,
      'simulatedAuthorizationReady': true,
      'simulatorOnlyAuthorization': true,
      'physicalDeviceClaimed': false,
      'hardwareBackedCustodyClaimed': false,
      'realBiometricClaimed': false,
      'productionReleaseClaimed': false,
      'rawDeviceIdentifierIncluded': false,
      'rawPrivateMaterialIncluded': false,
    };
    final encoded = base64Url.encode(utf8.encode(jsonEncode(summary)));
    // The host verifier accepts only this fixed boolean-only summary.
    // ignore: avoid_print
    print('$_sentinel$encoded');
  });
}

void _expectSimulatedAuthorizationReady(
  String platform,
  Map<String, dynamic> authorization,
) {
  final simulatorAuthorizationReady = platform == 'android'
      ? authorization['ok'] == true
      : authorization['localAuthenticationAvailable'] == true &&
            authorization['keychainUserPresencePolicyReady'] == true &&
            authorization['authenticated'] == true &&
            authorization['addStatus'] == 'ok' &&
            authorization['interactiveReadStatus'] == 'ok' &&
            authorization['deleteStatus'] == 'ok';
  expect(
    simulatorAuthorizationReady,
    true,
    reason: jsonEncode(_authorizationDiagnostic(authorization)),
  );
  expect(authorization['authenticated'], true);
  expect(authorization['systemCredentialPromptStarted'], true);
  expect(authorization['systemCredentialPromptCompleted'], true);
  expect(authorization['appPasswordPromptUsed'], false);
  expect(authorization['appCredentialPromptUsed'], false);
  expect(authorization['keyMaterialExported'], false);
  if (platform == 'android') {
    expect(authorization['platform'], 'android');
    expect(authorization['authorizationGrantActive'], true);
    expect(authorization['authorizationGrantPersisted'], false);
    expect(authorization['systemAuthenticationOnly'], true);
  } else {
    expect(authorization['platform'], 'ios');
    expect(authorization['provider'], 'LocalAuthentication');
    expect(authorization['localAuthenticationAvailable'], true);
    expect(authorization['keychainUserPresencePolicyReady'], true);
    expect(authorization['nonInteractiveReadBlocked'], isA<bool>());
    expect(
      authorization['failClosedWhenInteractionNotAllowed'],
      authorization['nonInteractiveReadBlocked'],
    );
    expect(
      authorization['cancelOrAuthFailureProbeRequiredForProduction'],
      true,
    );
    expect(authorization['productionReady'], false);
    expect(authorization['deleteStatus'], 'ok');
    expect(authorization['deleteDiagnosticCategory'], 'ready');
    expect(authorization['rawSecretMaterialIncluded'], false);
    expect(authorization['biometricDataHandledByApp'], false);
  }
}

Map<String, dynamic> _authorizationDiagnostic(
  Map<String, dynamic> authorization,
) {
  const keys = <String>[
    'localAuthenticationAvailable',
    'biometryType',
    'keychainUserPresencePolicyReady',
    'nonInteractiveReadBlocked',
    'failClosedWhenInteractionNotAllowed',
    'addStatus',
    'addDiagnosticCategory',
    'nonInteractiveReadStatus',
    'nonInteractiveReadDiagnosticCategory',
    'interactiveReadStatus',
    'interactiveReadDiagnosticCategory',
    'deleteStatus',
    'deleteDiagnosticCategory',
    'localAuthenticationDiagnosticCategory',
  ];
  return <String, dynamic>{for (final key in keys) key: authorization[key]};
}

Map<String, dynamic> _map(Object? value) {
  return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
