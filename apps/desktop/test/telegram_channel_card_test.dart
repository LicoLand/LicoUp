import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/frontend/features/models/ui/telegram_channel_card.dart';

const _zhDelegates = [
  GlobalMaterialLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

const _zhLocales = [Locale('zh'), Locale('en')];

void main() {
  testWidgets('renders status, token actions, and empty pairing sections', (
    tester,
  ) async {
    final runner = _FakeTelegramRunner();
    await _pump(tester, runner);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('telegram-channel-card')), findsOneWidget);
    expect(find.text('Telegram 通道'), findsOneWidget);
    expect(find.byKey(const Key('telegram-channel-token-field')), findsOneWidget);
    expect(find.byKey(const Key('telegram-channel-save-token')), findsOneWidget);
    expect(find.byKey(const Key('telegram-channel-pairings-empty')), findsOneWidget);
    expect(find.byKey(const Key('telegram-channel-chats-empty')), findsOneWidget);
    expect(
      runner.calls.map((call) => call.join(' ')),
      contains('gateway channel telegram credentials status'),
    );
  });

  testWidgets('save token stops and starts gateway, then refreshes', (
    tester,
  ) async {
    final runner = _FakeTelegramRunner()..configured = false;
    final lifecycle = LlmGatewayLifecycleController(
      agentService: runner,
      readSettings: () async => const {},
      monitorInterval: Duration.zero,
    );
    await _pump(tester, runner, lifecycleController: lifecycle);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('telegram-channel-token-field')),
      '123456:ABC-DEF',
    );
    await tester.tap(find.byKey(const Key('telegram-channel-save-token')));
    await tester.pumpAndSettle();

    expect(
      runner.stdinCalls.single.args,
      const [
        'gateway',
        'channel',
        'telegram',
        'credentials',
        'set',
        '--stdin-json',
        'true',
      ],
    );
    expect(jsonDecode(runner.stdinCalls.single.body)['botToken'], '123456:ABC-DEF');
    expect(
      runner.calls.where(
        (call) => call.take(3).join(' ') == 'llm-gateway service stop',
      ),
      isNotEmpty,
    );
    expect(
      runner.calls.where(
        (call) => call.take(3).join(' ') == 'llm-gateway service start',
      ),
      isNotEmpty,
    );
    expect(find.textContaining('Token 已保存'), findsOneWidget);
    lifecycle.dispose();
  });

  testWidgets('approve pending pairing and revoke approved chat', (
    tester,
  ) async {
    final runner = _FakeTelegramRunner()
      ..configured = true
      ..pairings = [
        {
          'code': 'ABCD12',
          'chatId': 11,
          'userId': 22,
          'username': 'alice',
        },
      ]
      ..chats = [
        {
          'chatId': 99,
          'userId': 88,
          'username': 'bob',
          'paired': true,
        },
      ];
    await _pump(tester, runner);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('telegram-pairing-ABCD12')), findsOneWidget);
    expect(find.byKey(const Key('telegram-chat-99')), findsOneWidget);

    await tester.tap(find.byKey(const Key('telegram-pairing-approve-ABCD12')));
    await tester.pumpAndSettle();
    expect(
      runner.calls.map((call) => call.join(' ')),
      contains('gateway channel telegram pairing approve ABCD12'),
    );

    await tester.ensureVisible(
      find.byKey(const Key('telegram-chat-revoke-99')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('telegram-chat-revoke-99')));
    await tester.pumpAndSettle();
    expect(
      runner.calls.map((call) => call.join(' ')),
      contains('gateway channel telegram pairing revoke 99'),
    );
  });

  testWidgets('manual pairing code field approves entered code', (
    tester,
  ) async {
    final runner = _FakeTelegramRunner()..configured = true;
    await _pump(tester, runner);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('telegram-channel-pairing-code')),
      'xy9k2m',
    );
    await tester.tap(find.byKey(const Key('telegram-channel-approve-code')));
    await tester.pumpAndSettle();

    expect(
      runner.calls.map((call) => call.join(' ')),
      contains('gateway channel telegram pairing approve XY9K2M'),
    );
  });
}

Future<void> _pump(
  WidgetTester tester,
  _FakeTelegramRunner runner, {
  LlmGatewayLifecycleController? lifecycleController,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: _zhLocales,
      localizationsDelegates: _zhDelegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: TelegramChannelCard(
            agentService: runner,
            lifecycleController: lifecycleController,
          ),
        ),
      ),
    ),
  );
}

final class _StdinCall {
  _StdinCall(this.args, this.body);
  final List<String> args;
  final String body;
}

final class _FakeTelegramRunner implements AgentCommandRunner {
  final List<List<String>> calls = [];
  final List<_StdinCall> stdinCalls = [];
  bool configured = false;
  List<Map<String, dynamic>> pairings = const [];
  List<Map<String, dynamic>> chats = const [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.of(args));
    if (args.length >= 3 &&
        (args[0] == 'gateway' || args[0] == 'llm-gateway') &&
        args[1] == 'service') {
      final action = args[2];
      return {
        'ok': true,
        'state': action == 'stop' ? 'stopped' : 'running',
        'managed': true,
        'port': defaultLlmGatewayPort,
        'schemaVersion': 'licoup.gateway-runtime.v1',
      };
    }
    if (args.join(' ') ==
        'gateway channel telegram credentials status') {
      return {
        'ok': true,
        'configured': configured,
        'tokenSource': configured ? 'store' : 'none',
        'token': configured ? 'configured' : 'missing',
      };
    }
    if (args.join(' ') == 'gateway channel status') {
      return {
        'ok': true,
        'channels': {
          'telegram': {
            'state': configured ? 'running' : 'unconfigured',
            'configured': configured,
            'botUsername': configured ? 'licoup_bot' : null,
          },
        },
      };
    }
    if (args.join(' ') == 'gateway channel telegram pairing list') {
      return {
        'ok': true,
        'pairings': pairings,
        'chats': chats,
      };
    }
    if (args.length >= 5 &&
        args[0] == 'gateway' &&
        args[3] == 'pairing' &&
        args[4] == 'approve') {
      pairings = const [];
      return {'ok': true, 'approved': true};
    }
    if (args.length >= 5 &&
        args[0] == 'gateway' &&
        args[3] == 'pairing' &&
        args[4] == 'revoke') {
      final chatId = int.tryParse(args[5]) ?? 0;
      pairings = [
        for (final item in pairings)
          if (item['chatId'] != chatId) item,
      ];
      chats = [
        for (final item in chats)
          if (item['chatId'] != chatId) item,
      ];
      return {'ok': true, 'revoked': true, 'chatId': chatId};
    }
    if (args.join(' ') ==
        'gateway channel telegram credentials clear') {
      configured = false;
      return {'ok': true, 'configured': false};
    }
    throw UnsupportedError('unexpected cli: ${args.join(' ')}');
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    stdinCalls.add(_StdinCall(List.of(args), stdinText));
    calls.add(List.of(args));
    if (args.join(' ') ==
        'gateway channel telegram credentials set --stdin-json true') {
      configured = true;
      return {'ok': true, 'configured': true, 'tokenSource': 'store'};
    }
    throw UnsupportedError('unexpected stdin cli: ${args.join(' ')}');
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) {
    throw UnimplementedError();
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) {
    throw UnimplementedError();
  }
}
