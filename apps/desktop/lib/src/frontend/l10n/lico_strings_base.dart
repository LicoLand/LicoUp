import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/contracts/generated/client_error.g.dart';

class LicoStrings {
  const LicoStrings._(this.locale);

  factory LicoStrings.forPreference(String preference) {
    final preferred = localeForPreference(preference);
    return LicoStrings._(
      resolve(preferred ?? PlatformDispatcher.instance.locale),
    );
  }

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
  String get agentHub => isChinese ? '智能体中心' : 'Agent Hub';
  String get mobileRelay => isChinese ? '移动中转' : 'Mobile Relay';
  String get keys => isChinese ? '密钥' : 'Keys';
  String get modelGateway => isChinese ? '模型网关' : 'Model Gateway';
  String get mobilePairing => isChinese ? '移动配对' : 'Mobile Pairing';
  String get chatChannels => isChinese ? '聊天频道' : 'Chat Channels';
  String get settings => isChinese ? '设置' : 'Settings';
  String get general => isChinese ? '通用' : 'General';
  String get moreActions => isChinese ? '更多' : 'More';
  String get features => isChinese ? '功能' : 'Features';
  String get exit => isChinese ? '退出' : 'Exit';
  String get globalSearchHint => isChinese ? '搜索' : 'Search';
  String get sidebarSearchHint => isChinese ? '搜索' : 'Search';
  String get collapseSearch => isChinese ? '收起搜索' : 'Collapse search';
  String get language => isChinese ? '语言' : 'Language';
  String get followSystem => isChinese ? '跟随系统' : 'Follow System';
  String get chinese => isChinese ? '中文' : 'Chinese';
  String get english => isChinese ? '英文' : 'English';
  String localePreferenceLabel(String value) {
    return switch (LocalePreference.normalize(value)) {
      LocalePreference.chinese => '中文',
      LocalePreference.english => 'English',
      _ => isChinese ? '系统' : 'System',
    };
  }

  String conversationClientError(ClientError error) {
    if (error.isUnknown) {
      return isChinese
          ? '请求未完成。请保留当前输入并检查运行时后重试。'
          : 'The request did not complete. Keep your input, check the runtime, and try again.';
    }
    final agent = error.presentationArgs['agentLabel'];
    final runtime = error.presentationArgs['runtimeLabel'];
    final subject = agent ?? runtime;
    return switch (error.code) {
      ClientErrorCode.invalidRequest ||
      ClientErrorCode.agentIdentifierMissing ||
      ClientErrorCode.agentMessageMissing ||
      ClientErrorCode.agentMessageInputLimit =>
        isChinese ? '请检查请求内容后重试。' : 'Check the request and try again.',
      ClientErrorCode.agentRuntimeUnsupported =>
        isChinese
            ? '${subject ?? '所选智能体'} 不支持当前运行时，请选择受支持的智能体。'
            : '${subject ?? 'The selected agent'} does not support this runtime. Select a supported agent.',
      ClientErrorCode.nativeAgentRuntimeProfileUnavailable ||
      ClientErrorCode.nativeAgentExecutableUnavailable =>
        isChinese
            ? '${subject ?? '本地运行时'} 当前不可用，请安装或恢复运行时后重试。'
            : '${subject ?? 'The local runtime'} is unavailable. Install or restore it, then try again.',
      ClientErrorCode.agentConversationDispatchFailed ||
      ClientErrorCode.streamProtocolFailed =>
        isChinese
            ? '${subject ?? '智能体'} 未能完成发送。输入已保留，可以重试。'
            : '${subject ?? 'The agent'} could not complete the send. Your input was preserved so you can retry.',
      ClientErrorCode.terminalResultInvalid =>
        isChinese
            ? '运行时返回了无效的最终结果，请检查会话状态。'
            : 'The runtime returned an invalid terminal result. Review the conversation state.',
      _ =>
        isChinese
            ? '请求未完成，请检查运行时状态后重试。'
            : 'The request did not complete. Check the runtime and try again.',
    };
  }
}
