part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientControllerShellState on ClientController {
  String get appearancePresetLabel {
    return findAppearancePresetConfig(
      appearancePresetId,
      appearancePresetConfigs,
    ).labelFor(_strings.isChinese ? 'zh-CN' : 'en');
  }

  bool get mobileClientRuntimePlatform => _mobileClientRuntimePlatform;

  bool isMcpPluginBusy(String target) {
    return _mcpPluginBusyTargets.contains(target);
  }

  void _startMcpPluginTargetPolling() {
    _mcpPluginTargetScanTimer ??= Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(scanTargets(showProgress: false)),
    );
  }

  void _stopMcpPluginTargetPolling() {
    _mcpPluginTargetScanTimer?.cancel();
    _mcpPluginTargetScanTimer = null;
  }

  bool get _mobileClientRuntimePlatform =>
      _mobileClientRuntimePlatformOverride ??
      runtimePlatformBridge.isMobileClientRuntime;

  LicoStrings get _strings => LicoStrings.forLocale(
    LicoStrings.localeForPreference(localePreference) ??
        LicoStrings.resolvePreferred(null),
  );

  String get displayStatusMessage {
    if (statusMessage != _localizedStatusMessageSource) {
      return statusMessage;
    }
    return _strings.isChinese
        ? _localizedStatusMessageChinese
        : _localizedStatusMessageEnglish;
  }

  String get displayStatusCaption {
    return _strings.statusCaptionLabel(statusCaption);
  }

  void _setLocalizedStatusMessage(
    String chinese,
    String english, {
    String? displayChinese,
  }) {
    statusMessage = chinese;
    _localizedStatusMessageSource = chinese;
    _localizedStatusMessageChinese = displayChinese ?? chinese;
    _localizedStatusMessageEnglish = english;
  }

  ClientSection _mobileAllowedSection(ClientSection section) {
    if (!_mobileClientRuntimePlatform) {
      // Feed is a mobile-only surface; do not expose it on macOS/desktop.
      return section == ClientSection.feed ? ClientSection.agents : section;
    }
    return switch (section) {
      ClientSection.agents ||
      ClientSection.feed ||
      ClientSection.mobileRelay ||
      ClientSection.settings => section,
      _ => ClientSection.agents,
    };
  }
}
