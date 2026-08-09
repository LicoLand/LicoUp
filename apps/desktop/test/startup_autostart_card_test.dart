import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/settings/ui/startup_autostart_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('startup card toggles desktop silent gateway and mcp', (
    tester,
  ) async {
    final agent = _AutostartAgentService();
    final controller = ClientController(agentService: agent);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StartupAutostartCard(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('开启自启动'), findsOneWidget);
    expect(find.text('桌面客户端'), findsOneWidget);
    expect(find.text('后台进程'), findsOneWidget);
    expect(find.text('静默启动'), findsOneWidget);
    expect(find.text('LLM Gateway'), findsOneWidget);
    expect(find.text('本地 MCP 服务'), findsOneWidget);

    await tester.tap(find.byKey(const Key('startup-desktop-autostart')));
    await tester.pumpAndSettle();
    expect(
      agent.cliCalls,
      contains(
        equals([
          'autostart',
          'set',
          '--component',
          'desktop',
          '--enabled',
          'true',
          '--silent',
          'false',
        ]),
      ),
    );

    await tester.tap(find.byKey(const Key('startup-desktop-silent')));
    await tester.pumpAndSettle();
    expect(
      agent.cliCalls,
      contains(
        equals([
          'autostart',
          'set',
          '--component',
          'desktop',
          '--enabled',
          'true',
          '--silent',
          'true',
        ]),
      ),
    );

    await tester.tap(find.byKey(const Key('startup-gateway-autostart')));
    await tester.pumpAndSettle();
    expect(
      agent.cliCalls.lastWhere((args) => args.contains('gateway')),
      equals([
        'autostart',
        'set',
        '--component',
        'gateway',
        '--enabled',
        'true',
        '--port',
        '15722',
      ]),
    );

    await tester.tap(find.byKey(const Key('startup-mcp-autostart')));
    await tester.pumpAndSettle();
    expect(
      agent.cliCalls.lastWhere((args) => args.contains('mcp')),
      equals([
        'autostart',
        'set',
        '--component',
        'mcp',
        '--enabled',
        'true',
      ]),
    );
    expect(find.text('自启动设置已保存。'), findsOneWidget);
  });
}

final class _AutostartAgentService extends FakeAgentService {
  bool desktopEnabled = false;
  bool desktopSilent = false;
  bool gatewayEnabled = false;
  bool mcpEnabled = false;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'autostart') {
      cliCalls = [...cliCalls, List<String>.from(args)];
      if (args[1] == 'status') {
        return _status();
      }
      if (args[1] == 'set') {
        final component = _option(args, '--component');
        final enabled = _option(args, '--enabled') == 'true';
        final silent = _option(args, '--silent') == 'true';
        if (component == 'desktop') {
          desktopEnabled = enabled;
          desktopSilent = enabled && silent;
        } else if (component == 'gateway') {
          gatewayEnabled = enabled;
        } else if (component == 'mcp') {
          mcpEnabled = enabled;
        }
        return _status();
      }
    }
    return super.runCli(args);
  }

  Map<String, dynamic> _status() => {
    'ok': true,
    'schemaVersion': 'licoup.client-autostart.v1',
    'supported': true,
    'desktop': {
      'enabled': desktopEnabled,
      'silent': desktopSilent,
      'installed': desktopEnabled,
    },
    'gateway': {
      'ok': true,
      'supported': true,
      'enabled': gatewayEnabled,
      'installed': gatewayEnabled,
    },
    'mcp': {
      'enabled': mcpEnabled,
      'installed': mcpEnabled,
    },
  };

  String? _option(List<String> args, String name) {
    final index = args.indexOf(name);
    if (index < 0 || index + 1 >= args.length) return null;
    return args[index + 1];
  }
}
