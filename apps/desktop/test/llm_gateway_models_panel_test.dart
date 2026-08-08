import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_card.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_credentials_card.dart';

const _zhDelegates = [
  GlobalMaterialLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

const _zhLocales = [Locale('zh'), Locale('en')];

void main() {
  test(
    'authorization loads protected credentials once per client process',
    () async {
      final runner = _FakeCredentialsRunner()
        ..entries = [
          _entry(
            id: '11111111-1111-4111-8111-111111111111',
            provider: 'kimi',
            label: 'Valid key',
            created: _daysFromNow(-10),
            expires: _daysFromNow(20),
          ),
        ];
      final authorization = LlmVaultAuthorization();

      expect(await authorization.authorize(runner), isTrue);
      expect(await authorization.authorize(runner), isTrue);

      expect(runner.calls, [
        const ['llm-gateway', 'credentials', 'authorize'],
      ]);
      expect(authorization.authorizedCredentialIds, [
        '11111111-1111-4111-8111-111111111111',
      ]);
      authorization.dispose();
    },
  );

  test('automatic authorization skips an empty metadata inventory', () async {
    final runner = _FakeCredentialsRunner();
    final authorization = LlmVaultAuthorization();

    expect(await authorization.authorizeExisting(runner), isFalse);
    expect(authorization.failure, LlmVaultAuthorizationFailure.noCredentials);
    expect(runner.calls, [
      const ['llm-gateway', 'credentials', 'list'],
    ]);
    authorization.dispose();
  });

  testWidgets('inventory load failure does not request authorization', (
    tester,
  ) async {
    final runner = _FakeCredentialsRunner()..failOnList = true;
    await _pumpCredentials(tester, runner);
    await tester.pumpAndSettle();

    expect(find.text('授权'), findsNWidgets(2));
    expect(find.text('授权并启动'), findsNothing);
    expect(find.byKey(const Key('credentials-authorize')), findsOneWidget);
    expect(find.text('添加'), findsOneWidget);
    expect(find.byKey(const Key('credentials-table')), findsOneWidget);
    expect(find.text('模型服务商'), findsOneWidget);
    expect(find.text('密钥名称'), findsOneWidget);
    expect(find.text('创建时间'), findsOneWidget);
    expect(find.text('到期时间'), findsOneWidget);
    expect(find.text('密钥清单未能载入。'), findsOneWidget);
    expect(runner.calls.single, ['llm-gateway', 'credentials', 'list']);
  });

  testWidgets('public inventory renders provider, name, and expiry columns', (
    tester,
  ) async {
    final runner = _FakeCredentialsRunner()
      ..entries = [
        _entry(
          id: '11111111-1111-4111-8111-111111111111',
          provider: 'kimi',
          label: 'Valid key',
          created: _daysFromNow(-10),
          expires: _daysFromNow(20),
        ),
        _entry(
          id: '22222222-2222-4222-8222-222222222222',
          provider: 'deepseek',
          label: 'Expired key',
          created: _daysFromNow(-40),
          expires: _daysFromNow(-1),
        ),
        _entry(
          id: '33333333-3333-4333-8333-333333333333',
          provider: 'kimi',
          label: 'Legacy key',
          created: _daysFromNow(-100),
        ),
        _entry(
          id: '44444444-4444-4444-8444-444444444444',
          provider: 'kilo',
          label: 'Kilo key',
          created: _daysFromNow(-5),
          expires: _daysFromNow(15),
        ),
      ];
    await _pumpCredentials(tester, runner);
    await tester.pumpAndSettle();

    expect(runner.calls.single, ['llm-gateway', 'credentials', 'list']);
    expect(find.byKey(const Key('credentials-table')), findsOneWidget);
    expect(find.text('模型服务商'), findsOneWidget);
    expect(find.text('密钥名称'), findsOneWidget);
    expect(find.text('创建时间'), findsOneWidget);
    expect(find.text('到期时间'), findsOneWidget);
    expect(find.text('Kimi'), findsNWidgets(2));
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('Kilo'), findsOneWidget);
    expect(find.textContaining('（已到期）'), findsOneWidget);
    expect(find.text('永久'), findsOneWidget);
    expect(find.text('授权'), findsNWidgets(2));
    expect(find.text('授权并启动'), findsNothing);
    expect(find.byKey(const Key('credentials-authorize')), findsOneWidget);
    expect(
      tester
          .widget<Switch>(
            find.byKey(
              const Key(
                'credential-authorize-11111111-1111-4111-8111-111111111111',
              ),
            ),
          )
          .onChanged,
      isNull,
    );
  });

  testWidgets('cached inventory renders synchronously without a native read', (
    tester,
  ) async {
    final runner = _FakeCredentialsRunner();
    final authorization = LlmVaultAuthorization()
      ..adoptInventory({
        'entries': [
          _entry(
            id: '11111111-1111-4111-8111-111111111111',
            provider: 'kimi',
            label: 'Valid key',
            created: _daysFromNow(-10),
            expires: _daysFromNow(20),
          ),
        ],
      });

    await _pumpCredentials(tester, runner, authorization: authorization);

    expect(find.text('Valid key'), findsOneWidget);
    expect(find.text('尚未保存密钥。'), findsNothing);
    expect(runner.calls, isEmpty);
    authorization.dispose();
  });

  testWidgets('an empty public inventory says no keys are saved', (
    tester,
  ) async {
    final runner = _FakeCredentialsRunner();
    await _pumpCredentials(tester, runner);
    await tester.pumpAndSettle();

    expect(find.text('授权'), findsNWidgets(2));
    expect(find.text('授权并启动'), findsNothing);
    expect(find.byKey(const Key('credentials-authorize')), findsOneWidget);
    expect(find.text('尚未保存密钥。'), findsOneWidget);
  });

  testWidgets(
    'credential authorize toggle stays off until Gateway is running',
    (tester) async {
      final runner = _FakeCredentialsRunner()
        ..entries = [
          _entry(
            id: '11111111-1111-4111-8111-111111111111',
            provider: 'kimi',
            label: 'Valid key',
            created: _daysFromNow(-10),
            expires: _daysFromNow(20),
          ),
        ];
      final lifecycle = LlmGatewayLifecycleController(
        agentService: _FakeServiceRunner()
          ..statusResult = _statusPayload(state: 'stopped', managed: false),
        readSettings: () async => const {},
        monitorInterval: Duration.zero,
      );
      await lifecycle.initialize();
      await _pumpCredentials(tester, runner, lifecycleController: lifecycle);
      await tester.pumpAndSettle();

      final toggle = tester.widget<Switch>(
        find.byKey(
          const Key(
            'credential-authorize-11111111-1111-4111-8111-111111111111',
          ),
        ),
      );
      expect(toggle.value, isFalse);
      expect(toggle.onChanged, isNull);
      lifecycle.dispose();
    },
  );

  testWidgets(
    'credential authorize toggle authorizes one key and applies to Gateway',
    (tester) async {
      const credentialId = '11111111-1111-4111-8111-111111111111';
      final runner = _FakeCredentialsRunner()
        ..entries = [
          _entry(
            id: credentialId,
            provider: 'kimi',
            label: 'Valid key',
            created: _daysFromNow(-10),
            expires: _daysFromNow(20),
          ),
          _entry(
            id: '22222222-2222-4222-8222-222222222222',
            provider: 'deepseek',
            label: 'Other key',
            created: _daysFromNow(-10),
            expires: _daysFromNow(20),
          ),
        ];
      final serviceRunner = _FakeServiceRunner()
        ..statusResult = _statusPayload(state: 'running', pid: 42189);
      final lifecycle = LlmGatewayLifecycleController(
        agentService: serviceRunner,
        readSettings: () async => const {},
        monitorInterval: Duration.zero,
      );
      await lifecycle.initialize();
      expect(lifecycle.state, LlmGatewayRuntimeState.running);
      final authorization = LlmVaultAuthorization();
      await _pumpCredentials(
        tester,
        runner,
        authorization: authorization,
        lifecycleController: lifecycle,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('credential-authorize-$credentialId')));
      await tester.pumpAndSettle();

      expect(authorization.authorized, isTrue);
      expect(authorization.authorizedCredentialIds, [credentialId]);
      expect(
        authorization.isCredentialAuthorized(
          '22222222-2222-4222-8222-222222222222',
        ),
        isFalse,
      );
      expect(find.text('已授权该密钥。'), findsOneWidget);
      expect(
        runner.calls,
        contains(
          equals([
            'llm-gateway',
            'credentials',
            'authorize',
            '--credential-id',
            credentialId,
          ]),
        ),
      );
      expect(
        serviceRunner.calls.where((args) => args[2] == 'start'),
        hasLength(1),
      );
      expect(
        tester
            .widget<Switch>(
              find.byKey(Key('credential-authorize-$credentialId')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<Switch>(
              find.byKey(
                const Key(
                  'credential-authorize-22222222-2222-4222-8222-222222222222',
                ),
              ),
            )
            .value,
        isFalse,
      );
      lifecycle.dispose();
      authorization.dispose();
    },
  );

  testWidgets('credential authorize toggle can revoke one key independently', (
    tester,
  ) async {
    const credentialId = '11111111-1111-4111-8111-111111111111';
    final runner = _FakeCredentialsRunner()
      ..entries = [
        _entry(
          id: credentialId,
          provider: 'kimi',
          label: 'Valid key',
          created: _daysFromNow(-10),
          expires: _daysFromNow(20),
        ),
      ]
      ..authorizedIds = {credentialId};
    final serviceRunner = _FakeServiceRunner()
      ..statusResult = _statusPayload(
        state: 'running',
        pid: 42189,
        credentialsApplied: true,
      );
    final lifecycle = LlmGatewayLifecycleController(
      agentService: serviceRunner,
      readSettings: () async => const {},
      monitorInterval: Duration.zero,
    );
    await lifecycle.initialize();
    final authorization = LlmVaultAuthorization();
    expect(
      await authorization.authorizeCredential(runner, credentialId),
      isTrue,
    );
    await _pumpCredentials(
      tester,
      runner,
      authorization: authorization,
      lifecycleController: lifecycle,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('credential-authorize-$credentialId')));
    await tester.pumpAndSettle();

    expect(authorization.authorized, isFalse);
    expect(authorization.authorizedCredentialIds, isEmpty);
    expect(find.text('已撤销该密钥授权。'), findsOneWidget);
    expect(
      runner.calls,
      contains(
        equals([
          'llm-gateway',
          'credentials',
          'clear',
          '--credential-id',
          credentialId,
        ]),
      ),
    );
    expect(
      serviceRunner.calls.where((args) => args[2] == 'start'),
      hasLength(1),
    );
    expect(
      tester
          .widget<Switch>(find.byKey(Key('credential-authorize-$credentialId')))
          .value,
      isFalse,
    );
    lifecycle.dispose();
    authorization.dispose();
  });

  testWidgets('add dialog sends the chosen per-key validity period', (
    tester,
  ) async {
    final runner = _FakeCredentialsRunner();
    await _pumpCredentials(tester, runner);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(find.text('添加模型 API 密钥'), findsOneWidget);
    expect(find.byKey(const Key('new-key-validity')), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '密钥名称'), 'Share');
    await tester.enterText(
      find.widgetWithText(TextField, 'API Key'),
      'sk-test-1234567890',
    );
    await tester.tap(find.byKey(const Key('new-key-save')));
    await tester.pumpAndSettle();

    expect(runner.stdinCalls.single.args, [
      'llm-gateway',
      'credentials',
      'create',
      '--stdin-json',
      'true',
    ]);
    final body = jsonDecode(runner.stdinCalls.single.body) as Map;
    expect(body['provider'], 'kimi');
    expect(body['label'], 'Share');
    expect(body['apiKey'], 'sk-test-1234567890');
    expect(body['leaseDays'], 30);
  });

  testWidgets('add dialog can select the Kilo provider', (tester) async {
    final runner = _FakeCredentialsRunner();
    await _pumpCredentials(tester, runner);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(find.text('添加模型 API 密钥'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kilo').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '密钥名称'), 'Kilo main');
    await tester.enterText(
      find.widgetWithText(TextField, 'API Key'),
      'kilo-test-1234567890',
    );
    await tester.tap(find.byKey(const Key('new-key-save')));
    await tester.pumpAndSettle();

    final body = jsonDecode(runner.stdinCalls.single.body) as Map;
    expect(body['provider'], 'kilo');
    expect(body['label'], 'Kilo main');
    expect(body['apiKey'], 'kilo-test-1234567890');
    expect(body['leaseDays'], 30);
  });

  testWidgets('edit dialog renames a key and extends its validity', (
    tester,
  ) async {
    const id = '44444444-4444-4444-8444-444444444444';
    final runner = _FakeCredentialsRunner()
      ..entries = [
        _entry(
          id: id,
          provider: 'kimi',
          label: 'Share',
          created: _daysFromNow(-10),
          expires: _daysFromNow(20),
        ),
      ];
    await _pumpCredentials(tester, runner);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('credential-edit-$id')));
    await tester.pumpAndSettle();

    expect(find.text('编辑密钥'), findsOneWidget);
    expect(find.text('延长有效期'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('edit-key-label')), 'Renamed');
    await tester.tap(find.byKey(const Key('edit-key-extend')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+30 天').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('edit-key-save')));
    await tester.pumpAndSettle();

    expect(runner.stdinCalls.single.args, [
      'llm-gateway',
      'credentials',
      'update',
      id,
      '--stdin-json',
      'true',
    ]);
    final body = jsonDecode(runner.stdinCalls.single.body) as Map;
    expect(body, {'label': 'Renamed', 'extendDays': 30});
  });

  testWidgets('gateway card persists a validated loopback URL', (tester) async {
    final settings = _FakeSettings({'llmGatewayPort': 18080, 'other': true});
    await _pumpGateway(tester, settings, _FakeServiceRunner());
    await tester.pumpAndSettle();

    final urlField = find.descendant(
      of: find.byKey(const Key('gateway-url')),
      matching: find.byType(TextField),
    );
    final field = tester.widget<TextField>(urlField);
    expect(field.controller!.text, 'http://127.0.0.1:18080');
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);

    await tester.enterText(urlField, 'https://gateway.example.test');
    await tester.tap(find.byTooltip('保存 Gateway URL'));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的本地 Gateway URL。'), findsOneWidget);
    expect(settings.writes, isEmpty);

    await tester.enterText(urlField, 'http://127.0.0.1:18081');
    await tester.tap(find.byTooltip('保存 Gateway URL'));
    await tester.pumpAndSettle();
    expect(settings.writes.single, {'llmGatewayPort': 18081, 'other': true});
  });

  testWidgets('entering the card detects the service status once', (
    tester,
  ) async {
    final settings = _FakeSettings({});
    final runner = _FakeServiceRunner()
      ..statusResult = _statusPayload(state: 'running', pid: 42189);
    await _pumpGateway(tester, settings, runner);
    await tester.pumpAndSettle();

    expect(runner.calls.first, [
      'llm-gateway',
      'service',
      'status',
      '--port',
      '15722',
    ]);
    expect(find.byKey(const Key('gateway-service-status')), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('42189  ·  lico-llm-gateway'), findsOneWidget);
    expect(find.text('检测中…'), findsNothing);
  });

  testWidgets('entering the card reuses the monitored status without probing', (
    tester,
  ) async {
    final settings = _FakeSettings({});
    final runner = _FakeServiceRunner()
      ..statusResult = _statusPayload(state: 'running', pid: 42189);
    final lifecycle = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: settings.read,
      monitorInterval: Duration.zero,
    );
    await lifecycle.initialize();
    runner.calls.clear();

    await _pumpGateway(
      tester,
      settings,
      runner,
      lifecycleController: lifecycle,
    );
    await tester.pumpAndSettle();

    expect(runner.calls.where((args) => args[2] == 'status'), isEmpty);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('42189  ·  lico-llm-gateway'), findsOneWidget);
    lifecycle.dispose();
  });

  testWidgets('start runs the service without requesting authorization', (
    tester,
  ) async {
    final authorization = LlmVaultAuthorization();
    final runner = _FakeServiceRunner();
    await _pumpGateway(
      tester,
      _FakeSettings({}),
      runner,
      authorization: authorization,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('gateway-service-start')));
    await tester.pumpAndSettle();

    expect(authorization.authorized, isFalse);
    expect(runner.calls, isNot(contains(equals(['llm-gateway', 'authorize']))));
    expect(
      runner.calls,
      contains(equals(['llm-gateway', 'service', 'start', '--port', '15722'])),
    );
    expect(find.text('Gateway 已启动。'), findsOneWidget);
  });

  testWidgets('gateway cards and model chart use gateway request counters', (
    tester,
  ) async {
    final today = DateTime.now().toUtc();
    final day =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final runner = _FakeServiceRunner()
      ..usageResult = {
        'ok': true,
        'schemaVersion': 'licoup.llm-gateway-usage.v1',
        'days': [
          {
            'date': day,
            'agents': {'codex': 2, 'claude-code': 3},
            'models': {'kimi-k2': 4, 'deepseek-chat': 1},
          },
        ],
      };
    await _pumpGateway(tester, _FakeSettings({}), runner);
    await tester.pumpAndSettle();

    expect(
      runner.calls,
      contains(equals(const ['llm-gateway', 'service', 'usage'])),
    );
    expect(find.text('API 请求次数'), findsOneWidget);
    expect(find.text('kimi-k2'), findsOneWidget);
    expect(find.text('deepseek-chat'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('start runs the service and refreshes from the payload', (
    tester,
  ) async {
    final settings = _FakeSettings({});
    final runner = _FakeServiceRunner();
    final authorization = LlmVaultAuthorization()..authorized = true;
    await _pumpGateway(
      tester,
      settings,
      runner,
      locale: const Locale('en'),
      authorization: authorization,
    );
    await tester.pumpAndSettle();
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);

    await tester.tap(find.byKey(const Key('gateway-service-start')));
    await tester.pumpAndSettle();

    expect(
      runner.calls,
      contains(equals(['llm-gateway', 'service', 'start', '--port', '15722'])),
    );
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Gateway started.'), findsOneWidget);
  });

  testWidgets('stop stops a managed running gateway', (tester) async {
    final settings = _FakeSettings({});
    final runner = _FakeServiceRunner()
      ..statusResult = _statusPayload(state: 'running', pid: 42189);
    await _pumpGateway(tester, settings, runner);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('gateway-service-stop')));
    await tester.pumpAndSettle();

    expect(
      runner.calls,
      contains(equals(['llm-gateway', 'service', 'stop', '--port', '15722'])),
    );
    expect(find.text('未运行'), findsOneWidget);
    expect(find.text('Gateway 已停止。'), findsOneWidget);
  });

  testWidgets('a start failure keeps the stopped state with an error', (
    tester,
  ) async {
    final settings = _FakeSettings({});
    final runner = _FakeServiceRunner()
      ..startError = StateError('authorization cancelled');
    final authorization = LlmVaultAuthorization()..authorized = true;
    await _pumpGateway(tester, settings, runner, authorization: authorization);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('gateway-service-start')));
    await tester.pumpAndSettle();

    expect(find.text('Gateway 启动失败。'), findsOneWidget);
    expect(find.text('未运行'), findsOneWidget);
  });

  testWidgets('a status failure renders the unknown state without crashing', (
    tester,
  ) async {
    final settings = _FakeSettings({});
    final runner = _FakeServiceRunner()
      ..statusError = StateError('sidecar missing');
    await _pumpGateway(tester, settings, runner);
    await tester.pumpAndSettle();

    expect(find.text('状态未知'), findsOneWidget);
    expect(find.text('Gateway 状态检测失败。'), findsOneWidget);
    expect(find.byKey(const Key('gateway-service-start')), findsOneWidget);
  });
}

int _daysFromNow(int days) =>
    (DateTime.now().millisecondsSinceEpoch ~/ 1000) + days * 24 * 60 * 60;

Map<String, dynamic> _entry({
  required String id,
  required String provider,
  required String label,
  required int created,
  int? expires,
}) => {
  'credentialId': id,
  'provider': provider,
  'label': label,
  'createdAtEpochSeconds': created,
  'expiresAtEpochSeconds': ?expires,
};

Future<void> _pumpCredentials(
  WidgetTester tester,
  _FakeCredentialsRunner runner, {
  LlmVaultAuthorization? authorization,
  LlmGatewayLifecycleController? lifecycleController,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: _zhLocales,
      localizationsDelegates: _zhDelegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: LlmGatewayCredentialsCard(
            agentService: runner,
            authorization: authorization ?? LlmVaultAuthorization(),
            lifecycleController: lifecycleController,
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpGateway(
  WidgetTester tester,
  _FakeSettings settings,
  _FakeServiceRunner runner, {
  Locale locale = const Locale('zh'),
  LlmVaultAuthorization? authorization,
  LlmGatewayLifecycleController? lifecycleController,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: _zhLocales,
      localizationsDelegates: _zhDelegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: LlmGatewayCard(
            agentService: runner,
            authorization: authorization ?? LlmVaultAuthorization(),
            readSettings: settings.read,
            writeSettings: settings.write,
            lifecycleController: lifecycleController,
          ),
        ),
      ),
    ),
  );
}

final class _FakeSettings {
  _FakeSettings(this.content);
  final Map<String, Object?> content;
  final List<Map<String, Object?>> writes = [];

  Future<Map<String, Object?>> read() async => Map.of(content);

  Future<void> write(Map<String, Object?> next) async {
    writes.add(Map.of(next));
    content
      ..clear()
      ..addAll(next);
  }
}

final class _StdinCall {
  _StdinCall(this.args, this.body);
  final List<String> args;
  final String body;
}

final class _FakeCredentialsRunner implements AgentCommandRunner {
  final List<List<String>> calls = [];
  final List<_StdinCall> stdinCalls = [];
  List<Map<String, dynamic>> entries = const [];
  Set<String> authorizedIds = {};
  bool failOnList = false;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.of(args));
    if (failOnList) {
      throw StateError('authorization cancelled');
    }
    if (args.length > 2 && args[2] == 'authorize') {
      final idIndex = args.indexOf('--credential-id');
      if (idIndex >= 0 && idIndex + 1 < args.length) {
        authorizedIds.add(args[idIndex + 1]);
      } else {
        authorizedIds = {
          for (final entry in entries) '${entry['credentialId']}',
        };
      }
      return {
        'ok': true,
        'schemaVersion': 'licoup.llm-gateway-authorization.v1',
        'authorized': authorizedIds.isNotEmpty,
        'providers': ['kimi', 'deepseek'],
        'authorizedCredentialIds': authorizedIds.toList(),
      };
    }
    if (args.length > 2 && args[2] == 'clear') {
      final idIndex = args.indexOf('--credential-id');
      if (idIndex >= 0 && idIndex + 1 < args.length) {
        authorizedIds.remove(args[idIndex + 1]);
      } else {
        authorizedIds = {};
      }
      return {
        'ok': true,
        'schemaVersion': 'licoup.llm-gateway-authorization.v1',
        'authorized': authorizedIds.isNotEmpty,
        'providers': authorizedIds.isEmpty
            ? const <String>[]
            : const ['kimi', 'deepseek'],
        'authorizedCredentialIds': authorizedIds.toList(),
      };
    }
    return {'ok': true, 'entries': entries, 'leaseDays': 7};
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    stdinCalls.add(_StdinCall(List.of(args), stdinText));
    return {'ok': true, 'entries': entries, 'leaseDays': 7};
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

Map<String, dynamic> _statusPayload({
  required String state,
  bool managed = true,
  int? pid,
  int port = 15722,
  bool credentialsApplied = false,
}) => {
  'ok': true,
  'schemaVersion': 'licoup.llm-gateway-service.v1',
  'state': state,
  'managed': managed,
  'pid': pid,
  'processName': pid == null ? null : 'lico-llm-gateway',
  'port': port,
  'credentialsLoaded': credentialsApplied,
  'credentialsApplied': credentialsApplied,
  'modelReady': state == 'running' && credentialsApplied,
  'configPath': 'synthetic/llm-gateway.json',
  'logPath': 'synthetic/llm-gateway.log',
};

final class _FakeServiceRunner implements AgentCommandRunner {
  final List<List<String>> calls = [];
  Map<String, dynamic> statusResult = _statusPayload(
    state: 'stopped',
    managed: false,
  );
  Object? statusError;
  Map<String, dynamic>? startResult;
  Object? startError;
  Map<String, dynamic>? stopResult;
  Object? stopError;
  Map<String, dynamic> authorizationResult = {
    'ok': true,
    'schemaVersion': 'licoup.llm-gateway-authorization.v1',
    'authorized': true,
    'providers': const ['kimi'],
    'authorizedCredentialIds': const <String>[
      '11111111-1111-4111-8111-111111111111',
    ],
  };
  Completer<Map<String, dynamic>>? authorizationCompletion;
  Map<String, dynamic> usageResult = {
    'ok': true,
    'schemaVersion': 'licoup.llm-gateway-usage.v1',
    'days': const [],
  };

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.of(args));
    switch (args.length > 2 ? args[2] : '') {
      case 'authorize':
        final completion = authorizationCompletion;
        return completion == null ? authorizationResult : completion.future;
      case 'list':
        return const {'ok': true, 'entries': [], 'leaseDays': 7};
      case 'usage':
        return usageResult;
      case 'status':
        final error = statusError;
        if (error != null) throw error;
        return statusResult;
      case 'initialize':
        return statusResult;
      case 'start':
        final error = startError;
        if (error != null) throw error;
        return startResult ?? _statusPayload(state: 'running', pid: 42189);
      case 'stop':
        final error = stopError;
        if (error != null) throw error;
        return stopResult ?? _statusPayload(state: 'stopped', managed: false);
      default:
        throw StateError('unexpected CLI args: $args');
    }
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => throw UnimplementedError('runCliWithStdin');

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
