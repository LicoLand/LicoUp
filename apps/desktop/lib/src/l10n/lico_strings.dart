import 'dart:ui';

import 'package:flutter/widgets.dart';

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

  static LicoStrings of(BuildContext context) {
    return LicoStrings._(resolve(Localizations.localeOf(context)));
  }

  static LicoStrings forLocale(Locale locale) {
    return LicoStrings._(resolve(locale));
  }

  String get appTitle => isChinese ? 'LicoLite 客户端' : 'LicoLite Client';
  String get agents => isChinese ? '智能体' : 'Agents';
  String get mcpPlugins => isChinese ? 'MCP 插件' : 'MCP Plugins';
  String get skillHub => isChinese ? '技能中心' : 'Skill Hub';
  String get modelForwarding => isChinese ? '模型转发' : 'Model Forwarding';
  String get mobileRelay => isChinese ? '移动中转' : 'Mobile Relay';
  String get activity => isChinese ? '活动与快照' : 'Activity And Snapshots';
  String get runtime => isChinese ? '运行时' : 'Runtime';
  String get settings => isChinese ? '设置' : 'Settings';

  String get addTarget => isChinese ? '添加目标' : 'Add target';
  String get adding => isChinese ? '添加中...' : 'Adding...';
  String get rescan => isChinese ? '重新扫描' : 'Rescan';
  String get scanning => isChinese ? '扫描中...' : 'Scanning...';
  String get scanningLocalAgents =>
      isChinese ? '正在扫描本机智能体...' : 'Scanning local agents...';
  String get noLocalAgentsFound =>
      isChinese ? '未发现本机智能体' : 'No local agents found';
  String get selectAgentToView => isChinese
      ? '选择一个智能体查看历史并对话'
      : 'Select an agent to view histories and chat';

  String get target => isChinese ? '目标' : 'Target';
  String get configPath => isChinese ? '配置路径' : 'Config path';
  String get binaryPath => isChinese ? '程序路径' : 'Binary path';
  String get historyRoot => isChinese ? '历史目录' : 'History root';
  String get cancel => isChinese ? '取消' : 'Cancel';
  String get inspect => isChinese ? '查看' : 'Inspect';
  String get plan => isChinese ? '计划' : 'Plan';

  String get configured => isChinese ? '已配置' : 'Configured';
  String get detected => isChinese ? '已检测到' : 'Detected';
  String get manual => isChinese ? '手动添加' : 'Manual';
  String get unavailable => isChinese ? '不可用' : 'Unavailable';
  String get notConfigured => isChinese ? '未配置' : 'Not configured';

  String get historyConversations =>
      isChinese ? '历史对话' : 'Conversation history';
  String conversationCount(int count) =>
      isChinese ? '$count 条对话' : '$count conversations';
  String get loading => isChinese ? '加载中...' : 'Loading...';
  String get loadingNativeHistories =>
      isChinese ? '正在加载原生智能体历史...' : 'Loading native agent histories...';
  String get noNativeHistories =>
      isChinese ? '暂无原生智能体历史' : 'No native agent histories yet';
  String get deleteNativeHistory =>
      isChinese ? '删除原生智能体历史' : 'Delete native agent history';
  String messagesCount(int count) =>
      isChinese ? '$count 条消息' : '$count messages';
  String get noMessagesInHistory =>
      isChinese ? '这条原生智能体历史里没有消息' : 'No messages in this native agent history';

  String get keywords => isChinese ? '关键词' : 'Keywords';
  String get archiveDirectory => isChinese ? '归档目录' : 'Archive directory';
  String get archive => isChinese ? '归档' : 'Archive';
  String recordsCount(String count) =>
      isChinese ? '$count 条记录' : '$count records';

  String get you => isChinese ? '你' : 'You';
  String get agent => isChinese ? '智能体' : 'Agent';
  String messageTarget(String targetLabel) =>
      isChinese ? '发送给 $targetLabel' : 'Message $targetLabel';
  String get send => isChinese ? '发送' : 'Send';
}
