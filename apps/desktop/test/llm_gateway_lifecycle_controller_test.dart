import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_notification_bell.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

void main() {
  test(
    'desktop bootstrap starts the service without credential authorization',
    () async {
      final service = _GatewayBootstrapAgentService();
      final controller = ClientController(
        agentService: service,
        llmGatewayMonitorInterval: Duration.zero,
        mobileClientRuntimePlatformOverride: false,
      );
      addTearDown(controller.dispose);

      await controller.initializeLlmGateway();

      expect(service.calls, [
        [
          'llm-gateway',
          'service',
          'initialize',
          '--port',
          '$defaultLlmGatewayPort',
        ],
      ]);
      expect(controller.llmVaultAuthorization.authorized, isFalse);
      expect(
        controller.llmGatewayLifecycleController.state,
        LlmGatewayRuntimeState.running,
      );
    },
  );

  test(
    'desktop bootstrap leaves an empty gateway running without auth',
    () async {
      final service = _GatewayBootstrapAgentService()..inventoryIsEmpty = true;
      final controller = ClientController(
        agentService: service,
        llmGatewayMonitorInterval: Duration.zero,
        mobileClientRuntimePlatformOverride: false,
      );
      addTearDown(controller.dispose);

      await controller.initializeLlmGateway();

      expect(service.calls, [
        [
          'llm-gateway',
          'service',
          'initialize',
          '--port',
          '$defaultLlmGatewayPort',
        ],
      ]);
      expect(controller.llmVaultAuthorization.authorized, isFalse);
      expect(
        controller.llmGatewayLifecycleController.state,
        LlmGatewayRuntimeState.running,
      );
    },
  );

  test(
    'initialization starts once and an observed crash can be restarted',
    () async {
      final runner = _GatewayRunner();
      final controller = LlmGatewayLifecycleController(
        agentService: runner,
        readSettings: () async => {'llmGatewayPort': 18080},
        monitorInterval: Duration.zero,
      );

      await controller.initialize();
      expect(controller.state, LlmGatewayRuntimeState.running);
      expect(controller.notice, isNull);
      expect(runner.calls.single, [
        'llm-gateway',
        'service',
        'initialize',
        '--port',
        '18080',
      ]);

      runner.statusState = 'stopped';
      await controller.pollNow();
      expect(controller.notice, LlmGatewayNoticeKind.unexpectedExit);

      await controller.restart();
      expect(controller.state, LlmGatewayRuntimeState.running);
      expect(controller.notice, isNull);
      expect(runner.calls.last, [
        'llm-gateway',
        'service',
        'start',
        '--port',
        '18080',
      ]);
      controller.dispose();
    },
  );

  test('an intentional stop is not reported as a crash', () async {
    final runner = _GatewayRunner();
    final controller = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: () async => const {},
      monitorInterval: Duration.zero,
    );

    await controller.initialize();
    await controller.stop();
    await controller.pollNow();

    expect(controller.state, LlmGatewayRuntimeState.stopped);
    expect(controller.notice, isNull);
    controller.dispose();
  });

  testWidgets('notification-panel row exposes a direct restart action', (
    tester,
  ) async {
    final runner = _GatewayRunner()..failInitialize = true;
    final controller = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: () async => const {},
      monitorInterval: Duration.zero,
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Scaffold(body: LlmGatewayNotificationRow(controller: controller)),
      ),
    );

    expect(
      find.byKey(const Key('llm-gateway-notification-item')),
      findsOneWidget,
    );
    expect(find.text('Restart'), findsOneWidget);

    runner.failInitialize = false;
    await tester.tap(find.byKey(const Key('llm-gateway-restart-action')));
    await tester.pumpAndSettle();

    expect(controller.notice, isNull);
    expect(
      find.byKey(const Key('llm-gateway-notification-item')),
      findsNothing,
    );
    controller.dispose();
  });
}

final class _GatewayBootstrapAgentService extends AgentService {
  _GatewayBootstrapAgentService() : super(persistentStdioRpcEnabled: false);

  final List<List<String>> calls = [];
  bool inventoryIsEmpty = false;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.of(args));
    if (args.length == 3 &&
        args[0] == 'llm-gateway' &&
        args[1] == 'credentials' &&
        args[2] == 'list') {
      return {
        'ok': true,
        'entries': inventoryIsEmpty
            ? const []
            : const [
                {'credentialId': 'synthetic'},
              ],
      };
    }
    if (args.length == 3 &&
        args[0] == 'llm-gateway' &&
        args[1] == 'credentials' &&
        args[2] == 'authorize') {
      return const {
        'ok': true,
        'authorized': true,
        'providers': ['kimi', 'deepseek'],
      };
    }
    return {
      'ok': true,
      'state': 'running',
      'managed': true,
      'pid': 42,
      'port': defaultLlmGatewayPort,
      'credentialsApplied': args[2] == 'start',
      'modelReady': args[2] == 'start',
    };
  }
}

final class _GatewayRunner implements AgentCommandRunner {
  final List<List<String>> calls = [];
  bool failInitialize = false;
  String statusState = 'running';

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.of(args));
    final operation = args[2];
    if (operation == 'initialize' && failInitialize) {
      throw StateError('authorization_required');
    }
    if (operation == 'stop') statusState = 'stopped';
    if (operation == 'start' || operation == 'initialize') {
      statusState = 'running';
    }
    return {
      'ok': true,
      'schemaVersion': 'licoup.llm-gateway-service.v1',
      'state': operation == 'status' ? statusState : statusState,
      'managed': statusState == 'running',
      'pid': statusState == 'running' ? 42 : null,
      'port': int.parse(args.last),
      'configPath': 'synthetic/config.json',
      'logPath': 'synthetic/gateway.log',
    };
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
