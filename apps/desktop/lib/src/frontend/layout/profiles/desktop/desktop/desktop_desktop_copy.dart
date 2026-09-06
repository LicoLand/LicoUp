import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// Desktop-profile-owned copy. l10n table edits are owned by another task, so
/// every Desktop-only string resolves here from the active locale.
abstract final class DesktopDesktopCopy {
  static String dockFolderLabel(LicoStrings strings) =>
      strings.isChinese ? '文件夹' : 'Folder';

  static String dockSearchHint(LicoStrings strings) =>
      strings.isChinese ? '搜索或输入命令' : 'Search or type a command';

  static String appStoreTitle(LicoStrings strings) =>
      strings.isChinese ? '功能' : 'Features';

  static String closeAppTooltip(LicoStrings strings) =>
      strings.isChinese ? '关闭' : 'Close';

  static String openAppStoreTooltip(LicoStrings strings) =>
      strings.isChinese ? '打开功能面板' : 'Open the app store';

  static String pluginSlotLabel(LicoStrings strings) =>
      strings.isChinese ? '插件即将推出' : 'Plugins coming soon';
}
