import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/presentation/layout_selection.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agents_empty_state.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/mobile_widgets_page.dart';
import 'package:flutter_client/src/frontend/features/local_runtime/ui/local_runtime_panel.dart';
import 'package:flutter_client/src/frontend/features/mcp_plugins/ui/mcp_plugins_panel.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final chinese = LicoStrings.forLocale(const Locale('zh'));
  final english = LicoStrings.forLocale(const Locale('en'));

  test('usage and report chrome follows the selected locale', () {
    expect(chinese.usageOverTime, '用量趋势');
    expect(english.usageOverTime, 'Usage Over Time');
    expect(chinese.byAgent, '智能体');
    expect(chinese.byModel, '模型');
    expect(english.byAgent, 'By Agent');
    expect(english.byModel, 'By Model');
    expect(chinese.apiPriceEstimate, 'API 价格预估');
    expect(english.apiPriceEstimate, 'Estimated API Price');
    expect(chinese.lastDays(30), '最近 30 天');
    expect(english.lastDays(30), 'Last 30 days');
  });

  test('layout catalog metadata and selection states are localized safely', () {
    expect(chinese.layoutProfile, '界面布局');
    expect(english.layoutProfile, 'Interface Layout');
    expect(
      chinese.layoutSelectionError(LayoutSelectionErrorCode.persistenceFailed),
      '无法保存布局，请稍后重试。',
    );
    expect(
      english.layoutSelectionError(
        LayoutSelectionErrorCode.invalidStoredPreference,
      ),
      'An invalid layout preference was ignored and the default was restored.',
    );
  });

  test('runtime and plugin chrome follows the selected locale', () {
    expect(chinese.runtimeModules, '运行时模块');
    expect(english.runtimeModules, 'Runtime Modules');
    expect(chinese.scanTargetsBeforeManagingMcp, '请先扫描目标，再管理 MCP 与 ACP 插件。');
    expect(
      english.scanTargetsBeforeManagingMcp,
      'Run a target scan before managing MCP and ACP plugins.',
    );
    expect(chinese.mcpPluginColumn, 'MCP 插件');
    expect(english.acpPluginColumn, 'ACP plugin');
    expect(chinese.runtimeGroupLabel('model-forwarding'), '模型转发');
    expect(english.runtimeGroupLabel('model-forwarding'), 'Model Forwarding');
  });

  test('skill hub chrome is localized without changing skill content', () {
    expect(chinese.publicSkills, '公共技能');
    expect(english.publicSkills, 'Public Skills');
    expect(chinese.installFromGitHub, '从 GitHub 安装');
    expect(english.installFromGitHub, 'Install from GitHub');
    expect(chinese.noDescription, '暂无描述');
    expect(english.noDescription, 'No description');
  });

  test(
    'status captions are translated while unknown source text is preserved',
    () {
      expect(chinese.statusCaptionLabel('Mobile relay'), '移动中转');
      expect(english.statusCaptionLabel('Mobile relay'), 'Mobile relay');
      expect(chinese.statusCaptionLabel('ChatGPT'), 'ChatGPT');
      expect(english.statusCaptionLabel('ChatGPT'), 'ChatGPT');
    },
  );

  test(
    'controller status display switches locale without rewriting source state',
    () {
      final controller = ClientController();
      addTearDown(controller.dispose);

      controller.localePreference = 'zh';
      expect(controller.displayStatusMessage, '等待扫描目标适配器。');
      controller.statusCaption = 'Mobile relay';
      expect(controller.displayStatusCaption, '移动中转');

      controller.localePreference = 'en';
      expect(
        controller.displayStatusMessage,
        'Waiting to scan target adapters.',
      );
      expect(controller.displayStatusCaption, 'Mobile relay');
      expect(controller.statusMessage, '等待扫描目标适配器。');
    },
  );

  testWidgets(
    'Chinese locale removes English chrome from empty agent and MCP views',
    (tester) async {
      final controller = ClientController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _LocalizedTestApp(
          child: Column(
            children: [
              AgentsEmptyState(onAddTarget: () {}),
              Expanded(child: McpPluginsPanel(controller: controller)),
            ],
          ),
        ),
      );

      expect(find.text('未检测到支持的目标。'), findsOneWidget);
      expect(find.text('添加目标'), findsOneWidget);
      expect(find.text('没有已扫描的智能体'), findsOneWidget);
      expect(find.text('请先扫描目标，再管理 MCP 与 ACP 插件。'), findsOneWidget);
      expect(find.text('No supported targets detected.'), findsNothing);
      expect(find.text('No scanned agents'), findsNothing);
    },
  );

  testWidgets('Chinese locale localizes local runtime interface chrome', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _LocalizedTestApp(child: LocalRuntimePanel(controller: controller)),
    );

    expect(find.text('运行时'), findsOneWidget);
    expect(find.text('配置'), findsOneWidget);
    expect(find.text('服务端信息'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('运行时模块'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('运行时模块'), findsOneWidget);
    expect(find.text('Runtime Modules'), findsNothing);
    expect(find.text('Configuration'), findsNothing);
  });

  testWidgets('Chinese locale localizes usage API widget details', (
    tester,
  ) async {
    final controller = ClientController()..isScanningAgentUsage = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _LocalizedTestApp(child: MobileWidgetsPage(controller: controller)),
    );

    expect(find.text('用量 / 费用 API'), findsOneWidget);
    expect(find.text('余额 API'), findsNWidgets(2));
    expect(find.text('账单 / 云控制台'), findsOneWidget);
    expect(find.text('Usage / Costs API'), findsNothing);
    expect(find.text('Balance API'), findsNothing);
    expect(find.text('Billing / Cloud console'), findsNothing);
  });
}

class _LocalizedTestApp extends StatelessWidget {
  const _LocalizedTestApp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(),
      home: Scaffold(body: child),
    );
  }
}
