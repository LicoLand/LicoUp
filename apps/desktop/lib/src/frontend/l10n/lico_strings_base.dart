import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/locale_preferences.dart';

class LicoStrings {
  const LicoStrings._(this.locale);

  static const supportedLocales = [Locale('en'), Locale('zh')];

  final Locale locale;

  bool get isChinese => locale.languageCode.toLowerCase() == 'zh';

  static Locale resolve(Locale? locale) {
    final languageCode = locale?.languageCode.toLowerCase();
    return languageCode == 'zh' ? const Locale('zh') : const Locale('en');
  }

  static Locale resolvePreferred(List<Locale>? locales) {
    if (locales == null || locales.isEmpty) {
      return resolve(PlatformDispatcher.instance.locale);
    }
    for (final locale in locales) {
      final languageCode = locale.languageCode.toLowerCase();
      if (languageCode == 'zh') {
        return const Locale('zh');
      }
      if (languageCode == 'en') {
        return const Locale('en');
      }
    }
    return const Locale('en');
  }

  static Locale? localeForPreference(String value) {
    return switch (LocalePreference.normalize(value)) {
      LocalePreference.chinese => const Locale('zh'),
      LocalePreference.english => const Locale('en'),
      _ => null,
    };
  }

  static LicoStrings of(BuildContext context) {
    return LicoStrings._(resolve(Localizations.localeOf(context)));
  }

  static LicoStrings forLocale(Locale locale) {
    return LicoStrings._(resolve(locale));
  }

  String get appTitle => 'LicoUp';
  String get connectMobileRelay =>
      isChinese ? '连接移动中转' : 'Connect Mobile Relay';
  String get openSettings => isChinese ? '打开设置' : 'Open Settings';
  String get agents => isChinese ? '智能体' : 'Agents';
  String get widgets => isChinese ? '小组件' : 'Widgets';
  String get add => isChinese ? '添加' : 'Add';
  String get addAgent => isChinese ? '添加智能体' : 'Add Agent';
  String get agentConfiguration => isChinese ? '智能体配置' : 'Agent Configuration';
  String get defaultPolicy => isChinese ? '默认策略' : 'Default Policy';
  String get monitoringCharts => isChinese ? '监控图表' : 'Monitoring Charts';
  String get openMonitoring => isChinese ? '打开 Token 用量' : 'Open Token Usage';
  String get tokenUsage => isChinese ? 'Token 用量' : 'Token Usage';
  String get tokenConsumption => isChinese ? 'Token 消耗量' : 'Token Consumption';
  String get totalTokens => 'Total';
  String get refreshUsage => isChinese ? '刷新用量' : 'Refresh Usage';
  String get noUsageReportYet => isChinese ? '暂无用量报表' : 'No usage report yet';
  String get confidence => isChinese ? '可信度' : 'Confidence';
  String get generated => isChinese ? '生成' : 'Generated';
  String get high => isChinese ? '高' : 'High';
  String get medium => isChinese ? '中' : 'Medium';
  String get low => isChinese ? '低' : 'Low';
  String get skillHub => isChinese ? '技能中心' : 'Skill Hub';
  String get pluginManagement => isChinese ? '插件管理' : 'Plugin Management';
  String get mobileRelay => isChinese ? '移动中转' : 'Mobile Relay';
  String get settings => isChinese ? '设置' : 'Settings';
  String get moreActions => isChinese ? '更多' : 'More';
  String get features => isChinese ? '功能' : 'Features';
  String get globalSearchHint => isChinese ? '搜索功能' : 'Search features';
  String get sidebarSearchHint => isChinese ? '搜索' : 'Search';
  String get collapseSearch => isChinese ? '收起搜索' : 'Collapse search';
  String get language => isChinese ? '语言' : 'Language';
  String get followSystem => isChinese ? '跟随系统' : 'Follow System';
  String get chinese => isChinese ? '中文' : 'Chinese';
  String get english => isChinese ? '英文' : 'English';
  String localePreferenceLabel(String value) {
    return switch (LocalePreference.normalize(value)) {
      LocalePreference.chinese => chinese,
      LocalePreference.english => english,
      _ => followSystem,
    };
  }
}
