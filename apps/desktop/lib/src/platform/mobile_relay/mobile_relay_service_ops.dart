import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_config_projector.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_native_dispatch.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

final class MobileRelayOperations {
  const MobileRelayOperations({
    MobileRelayNativeDispatch dispatch =
        const DefaultMobileRelayNativeDispatch(),
    MobileRelayConfigProjector configProjector =
        const MobileRelayConfigProjector(),
  }) : _dispatch = dispatch,
       _configProjector = configProjector;

  final MobileRelayNativeDispatch _dispatch;
  final MobileRelayConfigProjector _configProjector;
  Future<MobileRelayConfig> loadConfig({
    required AgentCommandRunner agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorizeSecrets = false,
  }) async {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      final output = await _dispatch.runMobile(
        bridge: _dispatch.bridgeForCurrentPlatform(bridge),
        action: 'mobile.relay.config.get',
        params: {
          'authorize': authorizeSecrets,
          'hydrateSecrets': authorizeSecrets,
        },
        authorize: authorizeSecrets,
      );
      return _configProjector.fromOutput(output);
    }
    final output = await _dispatch.runCli(agentService, [
      'mobile',
      'relay',
      'config',
      'get',
      '--authorize',
      authorizeSecrets.toString(),
      '--hydrate-secrets',
      authorizeSecrets.toString(),
    ]);
    return _configProjector.fromOutput(output);
  }

  Future<void> saveConfig({
    required AgentCommandRunner agentService,
    required MobileRelayConfig config,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      final params = <String, dynamic>{
        'stationBaseUrl': config.stationBaseUrl,
        'relayEnabled': config.relayEnabled,
        'pcClientId': config.pcClientId,
        'pcClientName': config.pcClientName,
        'pairingId': config.pairingId,
        'paired': config.paired,
      };
      if (config.mobileToken.trim().isNotEmpty) {
        params['mobileToken'] = config.mobileToken.trim();
      }
      await _dispatch.runMobile(
        bridge: _dispatch.bridgeForCurrentPlatform(bridge),
        action: 'mobile.relay.config.set',
        params: params,
      );
      return;
    }
    final params = <String, dynamic>{
      'stationBaseUrl': config.stationBaseUrl,
      'relayEnabled': config.relayEnabled,
      'pcClientId': config.pcClientId,
      'pcClientName': config.pcClientName,
      'pairingId': config.pairingId,
      'paired': config.paired,
    };
    if (config.mobileToken.trim().isNotEmpty) {
      params['mobileToken'] = config.mobileToken.trim();
    }
    await _dispatch.runPrivateCli(agentService, const [
      'mobile',
      'relay',
      'config',
      'set',
    ], params);
  }

  Future<MobileRelayConfig> resetPairing({
    required AgentCommandRunner agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      final output = await _dispatch.runMobile(
        bridge: _dispatch.bridgeForCurrentPlatform(bridge),
        action: 'mobile.relay.config.set',
        params: const {'resetPairing': true},
      );
      return _configProjector.fromOutput(output);
    }
    final output = await _dispatch.runCli(agentService, [
      'mobile',
      'relay',
      'config',
      'set',
      '--reset-pairing',
      'true',
    ]);
    return _configProjector.fromOutput(output);
  }

  Future<MobileRelayConfig> configureStation({
    required AgentCommandRunner agentService,
    required String stationBaseUrl,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      final output = await _dispatch.runMobile(
        bridge: _dispatch.bridgeForCurrentPlatform(bridge),
        action: 'mobile.relay.config.set',
        params: {'stationBaseUrl': stationBaseUrl.trim()},
      );
      return _configProjector.fromOutput(output);
    }
    final output = await _dispatch.runCli(agentService, [
      'mobile',
      'relay',
      'config',
      'set',
      '--station-base-url',
      stationBaseUrl.trim(),
    ]);
    return _configProjector.fromOutput(output);
  }

  Future<Map<String, dynamic>> createPairing({
    required AgentCommandRunner agentService,
  }) {
    if (_dispatch.isIOS) {
      throw _mobileRelayDesktopOnlyUnsupported();
    }
    return _dispatch.runCli(agentService, [
      'mobile',
      'relay',
      'pairing',
      'create',
    ]);
  }

  Future<Map<String, dynamic>> refreshPairingStatus({
    required AgentCommandRunner agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _dispatch.runMobile(
        bridge: _dispatch.bridgeForCurrentPlatform(bridge),
        action: 'mobile.relay.pairing.status',
      );
    }
    return _dispatch.runCli(agentService, [
      'mobile',
      'relay',
      'pairing',
      'status',
    ]);
  }

  Future<Map<String, dynamic>> syncCommands({
    required AgentCommandRunner agentService,
    bool allowInteraction = true,
  }) {
    if (_dispatch.isIOS) {
      throw _mobileRelayDesktopOnlyUnsupported();
    }
    return _dispatch.runCli(agentService, [
      'mobile',
      'relay',
      'commands',
      'sync',
      '--allow-interaction',
      allowInteraction.toString(),
    ]);
  }

  Future<Map<String, dynamic>> claimPairing({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> invite,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _dispatch.runMobile(
        bridge: _dispatch.bridgeForCurrentPlatform(bridge),
        action: 'mobile.relay.pairing.claim',
        params: {'invite': invite},
        authorize: true,
      );
    }
    return _dispatch.runPrivateCli(
      agentService,
      const ['mobile', 'relay', 'pairing', 'claim'],
      {'invite': Map<String, dynamic>.unmodifiable(invite)},
    );
  }

  Future<Map<String, dynamic>> openExternalUrl({
    required AgentCommandRunner agentService,
    required String url,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      return {
        'ok': false,
        'status': 'unsupported_url',
        'message': 'Only https:// external links are allowed.',
      };
    }
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _dispatch.runMobile(
        bridge: _dispatch.bridgeForCurrentPlatform(bridge),
        action: 'external.url.open',
        params: {'url': trimmed},
      );
    }
    return _dispatch.openExternalHttps(uri);
  }
}

UnsupportedError _mobileRelayDesktopOnlyUnsupported() {
  return UnsupportedError(
    'This Mobile Relay action must be created by the desktop client.',
  );
}
