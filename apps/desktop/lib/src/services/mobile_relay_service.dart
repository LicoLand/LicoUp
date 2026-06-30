import 'dart:convert';

import 'agent_service.dart';
import 'mobile_relay_models.dart';
import 'secure_mesh_android_bridge.dart';

export 'mobile_relay_models.dart';

class MobileRelayService {
  const MobileRelayService();

  Future<MobileRelayConfig> loadConfig({
    required AgentService agentService,
  }) async {
    final output = await agentService.runCli([
      'mobile',
      'relay',
      'config',
      'get',
    ]);
    return _configFromOutput(output);
  }

  Future<void> saveConfig({
    required AgentService agentService,
    required MobileRelayConfig config,
  }) async {
    await agentService.runCli([
      'mobile',
      'relay',
      'config',
      'set',
      '--use-custom-gateway',
      config.useCustomGateway.toString(),
      '--custom-gateway-url',
      config.customGatewayUrl,
      '--relay-enabled',
      config.relayEnabled.toString(),
    ]);
  }

  Future<MobileRelayConfig> configureGateway({
    required AgentService agentService,
    required bool useCustomGateway,
    required String customGatewayUrl,
  }) async {
    final output = await agentService.runCli([
      'mobile',
      'relay',
      'config',
      'set',
      '--use-custom-gateway',
      useCustomGateway.toString(),
      '--custom-gateway-url',
      customGatewayUrl.trim(),
    ]);
    return _configFromOutput(output);
  }

  Future<Map<String, dynamic>> createPairing({
    required AgentService agentService,
  }) {
    return agentService.runCli(['mobile', 'relay', 'pairing', 'create']);
  }

  Future<Map<String, dynamic>> refreshPairingStatus({
    required AgentService agentService,
  }) {
    return agentService.runCli(['mobile', 'relay', 'pairing', 'status']);
  }

  Future<Map<String, dynamic>> syncCommands({
    required AgentService agentService,
  }) {
    return agentService.runCli(['mobile', 'relay', 'commands', 'sync']);
  }

  Future<Map<String, dynamic>> secureMeshStatus({
    required AgentService agentService,
  }) {
    return agentService.runCli(['secure-mesh', 'status']);
  }

  Future<Map<String, dynamic>> secureMeshAndroidRuntimeStatus({
    SecureMeshAndroidBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    return bridge.status();
  }

  Future<Map<String, dynamic>> writeSecureMeshAndroidRuntimeStatus({
    SecureMeshAndroidBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    return bridge.writeRuntimeStatus();
  }

  Future<Map<String, dynamic>> writeSecureMeshAndroidInteropProof({
    SecureMeshAndroidBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    return bridge.writeInteropProof();
  }

  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required AgentService agentService,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
    String ledgerPath = '',
    String completedAt = '',
  }) {
    final args = [
      'secure-mesh',
      'command',
      'execute',
      '--payload',
      jsonEncode(payload),
      '--context',
      jsonEncode(context),
    ];
    if (ledgerPath.trim().isNotEmpty) {
      args.addAll(['--ledger-path', ledgerPath.trim()]);
    }
    if (completedAt.trim().isNotEmpty) {
      args.addAll(['--completed-at', completedAt.trim()]);
    }
    return agentService.runCli(args);
  }

  Future<Map<String, dynamic>> evaluateSecureMeshDeviceTrust({
    required AgentService agentService,
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) {
    final args = [
      'secure-mesh',
      'device-trust',
      'evaluate',
      '--identity',
      jsonEncode(identity),
      '--trust-state',
      trustState,
      '--require-verified-device',
      requireVerifiedDevice.toString(),
      '--allow-unverified-read-only',
      allowUnverifiedReadOnly.toString(),
    ];
    if (previousIdentity != null) {
      args.addAll(['--previous-identity', jsonEncode(previousIdentity)]);
    }
    return agentService.runCli(args);
  }

  Future<Map<String, dynamic>> evaluateSecureMeshFileRoute({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
  }) {
    return agentService.runCli([
      'secure-mesh',
      'file',
      'route',
      '--manifest',
      jsonEncode(manifest),
    ]);
  }

  MobileRelayConfig _configFromOutput(Map<String, dynamic> output) {
    final config = output['config'];
    if (config is Map<String, dynamic>) {
      return MobileRelayConfig.fromJson(config);
    }
    return MobileRelayConfig.fromJson(output);
  }
}
