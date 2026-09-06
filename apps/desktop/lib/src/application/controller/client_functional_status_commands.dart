import 'package:licoup/src/application/controller/functional_status_runtime.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';

/// Locale-neutral functional status and notification commands.
mixin ClientFunctionalStatusCommands on AgentWorkspaceCoordinator {
  FunctionalStatusRuntime get functionalStatusRuntime;

  @override
  String get statusMessage => functionalStatusRuntime.messageSource;
  @override
  set statusMessage(String value) {
    functionalStatusRuntime.replaceMessage(value);
  }

  @override
  String get statusCaption => functionalStatusRuntime.caption;
  @override
  set statusCaption(String value) {
    functionalStatusRuntime.replaceCaption(value);
  }

  @override
  String get lastError => functionalStatusRuntime.lastError;
  @override
  set lastError(String value) {
    functionalStatusRuntime.replaceLastError(value);
  }

  void setLocalizedStatusMessage(
    String chinese,
    String english, {
    String? displayChinese,
  }) {
    functionalStatusRuntime.setLocalized(
      chinese,
      english,
      caption: statusCaption,
      displayChinese: displayChinese,
    );
  }

  void reportAppearanceReloadOutcome({required bool hasErrors}) {
    setLocalizedStatusMessage(
      hasErrors ? '外观预设已重新加载，部分配置无效。' : '外观预设已重新加载。',
      hasErrors
          ? 'Appearance presets reloaded, but some configurations are invalid.'
          : 'Appearance presets reloaded.',
    );
    statusCaption = 'Appearance';
  }

  void reportAppearanceReloadFailure() {
    lastError = 'appearance_preset_reload_failed';
    setLocalizedStatusMessage(
      '外观预设重新加载失败。',
      'Failed to reload appearance presets.',
    );
    statusCaption = 'Error';
  }

  @override
  void agentWorkspaceSetLocalizedStatusMessage(
    String chinese,
    String english, {
    String? displayChinese,
  }) => setLocalizedStatusMessage(
    chinese,
    english,
    displayChinese: displayChinese,
  );

  @override
  void agentWorkspacePublishNotification({
    required String id,
    required String messageChinese,
    required String messageEnglish,
    MessagingNotificationTone tone = MessagingNotificationTone.info,
    String code = '',
  }) {
    messagingNotificationCenter.publish(
      id: id,
      messageChinese: messageChinese,
      messageEnglish: messageEnglish,
      tone: tone,
      code: code,
    );
  }
}
