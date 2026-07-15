part of 'package:flutter_client/src/platform/native_client/agent_service.dart';

extension AgentServiceProxyBridgeActions on AgentService {
  Future<Map<String, dynamic>> proxyBridgeDetect() {
    return _runCli(['proxy-bridge', 'detect']);
  }

  Future<Map<String, dynamic>> proxyBridgeStatus() {
    return _runCli(['proxy-bridge', 'status']);
  }

  Future<Map<String, dynamic>> proxyBridgePlan({
    String targets = '',
    bool clientEnabled = true,
    bool wrapperEnabled = true,
  }) {
    final args = [
      'proxy-bridge',
      'plan',
      '--client-enabled',
      clientEnabled.toString(),
      '--wrapper-enabled',
      wrapperEnabled.toString(),
    ];
    _appendOptionalArg(args, '--targets', targets);
    return _runCli(args);
  }

  Future<Map<String, dynamic>> proxyBridgeApply({
    String targets = '',
    bool clientEnabled = true,
    bool wrapperEnabled = true,
  }) {
    final args = [
      'proxy-bridge',
      'apply',
      '--client-enabled',
      clientEnabled.toString(),
      '--wrapper-enabled',
      wrapperEnabled.toString(),
    ];
    _appendOptionalArg(args, '--targets', targets);
    return _runCli(args);
  }

  Future<Map<String, dynamic>> proxyBridgeRollback({
    bool removeWrappers = true,
  }) {
    return _runCli([
      'proxy-bridge',
      'rollback',
      '--remove-wrappers',
      removeWrappers.toString(),
    ]);
  }

  void _appendOptionalArg(List<String> args, String flag, String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      args.addAll([flag, trimmed]);
    }
  }
}
