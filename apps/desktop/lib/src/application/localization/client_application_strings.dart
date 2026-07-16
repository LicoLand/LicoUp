import 'dart:ui';

import 'package:flutter_client/src/contracts/locale_preferences.dart';

/// Minimal application-layer messages used by controllers.
///
/// UI copy remains in the frontend localization catalog. Keeping this small
/// application catalog separate prevents orchestration and state transitions
/// from importing the widget localization layer.
final class ClientApplicationStrings {
  const ClientApplicationStrings._(this.isChinese);

  factory ClientApplicationStrings.forPreference(String preference) {
    final normalized = LocalePreference.normalize(preference);
    final isChinese = switch (normalized) {
      LocalePreference.chinese => true,
      LocalePreference.english => false,
      _ =>
        PlatformDispatcher.instance.locale.languageCode.toLowerCase() == 'zh',
    };
    return ClientApplicationStrings._(isChinese);
  }

  final bool isChinese;

  String get defaultLabel => isChinese ? '默认' : 'Default';
  String get defaultPolicy => isChinese ? '默认策略' : 'Default Policy';
  String get notConfigured => isChinese ? '未配置' : 'Not configured';
  String get newConversation => isChinese ? '新对话' : 'New Conversation';
  String get directory => isChinese ? '目录' : 'Directory';

  String statusCaptionLabel(String value) {
    if (!isChinese) return value;
    return _chineseStatusCaptions[value.trim()] ?? value;
  }

  static const Map<String, String> _chineseStatusCaptions = {
    'Agent archive': '智能体归档',
    'Agent chat': '智能体对话',
    'Agent orchestration': '智能体编排',
    'Agent tabs': '智能体标签页',
    'Agent usage': '智能体用量',
    'Appearance': '外观',
    'Client logs': '客户端日志',
    'Conversation archive': '对话归档',
    'Error': '错误',
    'LicoArc client': '客户端',
    'Mobile agents': '移动端智能体',
    'Mobile relay': '移动中转',
    'Project archive': '项目归档',
    'Ready': '就绪',
    'Runtime': '运行时',
    'Secure Mesh': '安全网格',
    'Settings': '设置',
    'Skill Hub': '技能中心',
    'Snapshots': '快照',
    'Target inspect': '目标检查',
    'Targets': '目标',
  };
}
