import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_gateway_diagnostics.dart';
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

  test('an observed crash is recovered automatically', () async {
    final runner = _GatewayRunner();
    final controller = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: () async => {'llmGatewayPort': 18080},
      monitorInterval: Duration.zero,
      recoveryRetryDelay: Duration.zero,
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
    expect(controller.state, LlmGatewayRuntimeState.running);
    expect(controller.notice, isNull);
    expect(controller.autoRevealRevision, 1);
    expect(runner.calls.last, [
      'llm-gateway',
      'service',
      'start',
      '--port',
      '18080',
    ]);
    controller.dispose();
  });

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

  test(
    'two unavailable monitor checks trigger health-aware recovery',
    () async {
      final runner = _GatewayRunner()..statusFailuresRemaining = 2;
      final diagnostics = _DiagnosticCollector();
      final controller = LlmGatewayLifecycleController(
        agentService: runner,
        readSettings: () async => const {},
        monitorInterval: Duration.zero,
        recoveryRetryDelay: Duration.zero,
        diagnosticSink: diagnostics,
      );

      await controller.initialize();
      await controller.pollNow();
      expect(runner.startCalls, 0);
      await controller.pollNow();

      expect(runner.startCalls, 1);
      expect(controller.state, LlmGatewayRuntimeState.running);
      expect(controller.notice, isNull);
      expect(controller.autoRevealRevision, 1);
      expect(
        diagnostics.records.single.event,
        LlmGatewayDiagnosticEvent.monitorCheckFailed,
      );
      expect(diagnostics.records.single.errorCode, 'timeout');
      controller.dispose();
    },
  );

  test('initialization retries three times before terminal failure', () async {
    final runner = _GatewayRunner()
      ..failInitialize = true
      ..startFailuresRemaining = 3;
    final diagnostics = _DiagnosticCollector();
    final controller = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: () async => const {},
      monitorInterval: Duration.zero,
      recoveryRetryDelay: Duration.zero,
      diagnosticSink: diagnostics,
    );

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);

    expect(runner.startCalls, 3);
    expect(controller.recovering, isFalse);
    expect(controller.recoveryAttempt, 3);
    expect(controller.notice, LlmGatewayNoticeKind.recoveryFailed);
    expect(controller.autoRevealRevision, 0);
    expect(
      diagnostics.records.first.event,
      LlmGatewayDiagnosticEvent.initializationFailed,
    );
    expect(
      diagnostics.records
          .where(
            (record) =>
                record.event == LlmGatewayDiagnosticEvent.recoveryAttemptFailed,
          )
          .length,
      3,
    );
    expect(
      diagnostics.records.last.event,
      LlmGatewayDiagnosticEvent.recoveryExhausted,
    );
    expect(
      diagnostics.records.every(
        (record) => !record.errorCode.contains('private failure detail'),
      ),
      isTrue,
    );
    controller.dispose();
  });

  test(
    'automatic recovery stays circuit-broken after three failures',
    () async {
      final runner = _GatewayRunner();
      final controller = LlmGatewayLifecycleController(
        agentService: runner,
        readSettings: () async => const {},
        monitorInterval: Duration.zero,
        recoveryRetryDelay: Duration.zero,
      );
      await controller.initialize();
      runner
        ..statusState = 'stopped'
        ..startFailuresRemaining = 3;

      await controller.pollNow();
      expect(controller.notice, LlmGatewayNoticeKind.recoveryFailed);
      expect(runner.startCalls, 3);

      await controller.pollNow();
      expect(runner.startCalls, 3);

      await controller.restart();
      expect(runner.startCalls, 4);
      expect(controller.notice, isNull);
      expect(controller.state, LlmGatewayRuntimeState.running);
      controller.dispose();
    },
  );

  testWidgets('notification row spins while automatic recovery is active', (
    tester,
  ) async {
    final runner = _GatewayRunner();
    final controller = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: () async => const {},
      monitorInterval: Duration.zero,
      recoveryRetryDelay: Duration.zero,
    );
    await controller.initialize();

    runner.statusState = 'stopped';
    runner.startGate = Completer<void>();
    final recovery = controller.pollNow();
    await tester.pump();

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
    expect(
      find.byKey(const Key('llm-gateway-recovery-spinner')),
      findsOneWidget,
    );
    expect(find.textContaining('(1/3)'), findsOneWidget);

    await tester.runAsync(() async {
      runner.startGate!.complete();
      await recovery;
    });
    await tester.pump();
    expect(
      find.byKey(const Key('llm-gateway-notification-item')),
      findsNothing,
    );
    controller.dispose();
  });

  testWidgets('terminal recovery failure exposes an explicit retry', (
    tester,
  ) async {
    final runner = _GatewayRunner()
      ..failInitialize = true
      ..startFailuresRemaining = 3;
    final controller = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: () async => const {},
      monitorInterval: Duration.zero,
      recoveryRetryDelay: Duration.zero,
    );
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Scaffold(body: LlmGatewayNotificationRow(controller: controller)),
      ),
    );

    expect(find.text('Retry'), findsOneWidget);

    runner.startFailuresRemaining = 0;
    await tester.tap(find.byKey(const Key('llm-gateway-restart-action')));
    await tester.pumpAndSettle();

    expect(controller.notice, isNull);
    expect(
      find.byKey(const Key('llm-gateway-notification-item')),
      findsNothing,
    );
    controller.dispose();
  });

  test('overlapping monitor requests share one native status call', () async {
    final runner = _GatewayRunner();
    final controller = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: () async => const {},
      monitorInterval: Duration.zero,
      recoveryRetryDelay: Duration.zero,
    );
    await controller.initialize();
    runner.statusGate = Completer<void>();

    final first = controller.pollNow();
    final second = controller.pollNow();
    await Future<void>.delayed(Duration.zero);

    expect(identical(first, second), isTrue);
    expect(runner.statusCalls, 1);
    runner.statusGate!.complete();
    await Future.wait([first, second]);
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
  int startFailuresRemaining = 0;
  int statusFailuresRemaining = 0;
  int startCalls = 0;
  int statusCalls = 0;
  String statusState = 'running';
  Completer<void>? startGate;
  Completer<void>? statusGate;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.of(args));
    final operation = args[2];
    if (operation == 'initialize' && failInitialize) {
      throw const _CodedFailure('initialization_failed');
    }
    if (operation == 'status') {
      statusCalls += 1;
      await statusGate?.future;
      if (statusFailuresRemaining > 0) {
        statusFailuresRemaining -= 1;
        throw const _CodedFailure('timeout');
      }
    }
    if (operation == 'stop') statusState = 'stopped';
    if (operation == 'start') {
      startCalls += 1;
      await startGate?.future;
      if (startFailuresRemaining > 0) {
        startFailuresRemaining -= 1;
        throw const _CodedFailure('start_failed');
      }
      statusState = 'running';
    }
    if (operation == 'initialize') {
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

final class _CodedFailure implements Exception {
  const _CodedFailure(this.code);

  final String code;

  @override
  String toString() => 'private failure detail';
}

final class _DiagnosticCollector implements LlmGatewayDiagnosticSink {
  final List<LlmGatewayDiagnosticRecord> records = [];

  @override
  Future<void> record(LlmGatewayDiagnosticRecord record) async {
    records.add(record);
  }
}
