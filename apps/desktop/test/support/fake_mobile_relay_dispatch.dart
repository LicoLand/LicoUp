import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_native_dispatch.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

typedef FakeRelayCliHandler =
    Future<Map<String, dynamic>> Function(List<String> arguments);
typedef FakeRelayMobileHandler =
    Future<Map<String, dynamic>> Function({
      required String action,
      required Map<String, dynamic> params,
      required bool authorize,
    });

final class FakeAgentCommandRunner implements AgentCommandRunner {
  FakeAgentCommandRunner({this.onRunCli});

  final FakeRelayCliHandler? onRunCli;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    return onRunCli?.call(List<String>.from(args)) ?? const {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => runCli(args);

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) {
    return const Stream<Map<String, dynamic>>.empty();
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) {
    return const Stream<Map<String, dynamic>>.empty();
  }
}

final class FakeMobileRelayDispatch implements MobileRelayNativeDispatch {
  FakeMobileRelayDispatch({
    this.isAndroid = false,
    this.isIOS = false,
    this.cliResult = const {'ok': true},
    this.mobileResult = const {'ok': true},
    this.externalResult = const {'ok': true, 'status': 'opened'},
    this.onRunCli,
    this.onRunMobile,
  });

  @override
  final bool isAndroid;

  @override
  final bool isIOS;

  Map<String, dynamic> cliResult;
  Map<String, dynamic> mobileResult;
  Map<String, dynamic> externalResult;
  final FakeRelayCliHandler? onRunCli;
  final FakeRelayMobileHandler? onRunMobile;

  final List<List<String>> cliCalls = [];
  final List<({String action, Map<String, dynamic> params, bool authorize})>
  mobileCalls = [];
  final List<Uri> externalCalls = [];

  @override
  SecureMeshMobileBridge bridgeForCurrentPlatform(
    SecureMeshMobileBridge androidBridge,
  ) => androidBridge;

  @override
  Future<Map<String, dynamic>> runCli(
    AgentCommandRunner runner,
    List<String> arguments,
  ) async {
    final captured = List<String>.unmodifiable(arguments);
    cliCalls.add(captured);
    return onRunCli?.call(captured) ?? Map<String, dynamic>.from(cliResult);
  }

  @override
  Future<Map<String, dynamic>> runMobile({
    required SecureMeshMobileBridge bridge,
    required String action,
    Map<String, dynamic> params = const {},
    bool authorize = false,
  }) async {
    final capturedParams = Map<String, dynamic>.unmodifiable(params);
    mobileCalls.add((
      action: action,
      params: capturedParams,
      authorize: authorize,
    ));
    return onRunMobile?.call(
          action: action,
          params: capturedParams,
          authorize: authorize,
        ) ??
        Map<String, dynamic>.from(mobileResult);
  }

  @override
  Future<Map<String, dynamic>> openExternalHttps(Uri uri) async {
    externalCalls.add(uri);
    return Map<String, dynamic>.from(externalResult);
  }
}
