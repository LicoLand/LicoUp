import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final chinese = LicoStrings.forLocale(const Locale('zh'));
  final english = LicoStrings.forLocale(const Locale('en'));

  test('usage and report chrome follows the selected locale', () {
    expect(chinese.byAgent, '智能体');
    expect(chinese.byModel, '模型');
    expect(chinese.features, '功能');
    expect(chinese.modelGateway, '模型网关');
    expect(chinese.mobilePairing, '移动配对');
    expect(chinese.chatChannels, '聊天频道');
    expect(chinese.exit, '退出');
    expect(english.byAgent, 'By Agent');
    expect(english.byModel, 'By Model');
    expect(english.features, 'Features');
    expect(english.modelGateway, 'Model Gateway');
    expect(english.mobilePairing, 'Mobile Pairing');
    expect(english.chatChannels, 'Chat Channels');
    expect(english.exit, 'Exit');
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

  test('skill hub chrome is localized without changing skill content', () {
    expect(chinese.publicSkills, '公共技能');
    expect(english.publicSkills, 'Public Skills');
    expect(chinese.installFromGitHub, '从 GitHub 安装');
    expect(english.installFromGitHub, 'Install from GitHub');
    expect(chinese.noDescription, '暂无描述');
    expect(english.noDescription, 'No description');
    expect(chinese.moveToSystemTrash, '移入回收站');
    expect(english.moveToSystemTrash, 'Move to Trash');
    expect(chinese.trashSkillMessage('示例技能'), '“示例技能” 将移入系统回收站，可在回收站中恢复。');
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
    'Chinese locale removes English chrome from the empty agent view',
    (tester) async {
      await tester.pumpWidget(
        _LocalizedTestApp(
          child: Builder(
            builder: (context) {
              final strings = LicoStrings.of(context);
              return LicoEmptyState(
                icon: Icons.smart_toy_outlined,
                iconSize: 32,
                title: strings.noSupportedTargetsDetected,
                action: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(strings.addTarget),
                ),
              );
            },
          ),
        ),
      );

      expect(find.text('未检测到支持的目标。'), findsOneWidget);
      expect(find.text('添加目标'), findsOneWidget);
      expect(find.text('No supported targets detected.'), findsNothing);
    },
  );
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
