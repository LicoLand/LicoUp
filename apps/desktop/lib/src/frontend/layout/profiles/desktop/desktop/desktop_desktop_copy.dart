import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// Desktop-profile-owned copy: strings only the Desktop shell renders resolve
/// here from the active locale.
abstract final class DesktopDesktopCopy {
  static String dockLabel(LicoStrings strings) =>
      strings.isChinese ? '程序坞' : 'Dock';

  static String dockFolderLabel(LicoStrings strings) =>
      strings.isChinese ? '文件夹' : 'Folder';

  static String pluginCenterLabel(LicoStrings strings) =>
      strings.isChinese ? '插件中心' : 'Plugin Center';

  static String pluginPublisher(
    LicoStrings strings, {
    required bool official,
  }) => official
      ? (strings.isChinese ? 'LicoLand 官方' : 'LicoLand official')
      : (strings.isChinese ? '第三方' : 'Third party');

  static String dockOpen(LicoStrings strings) =>
      strings.isChinese ? '打开' : 'Open';

  static String dockQuit(LicoStrings strings) =>
      strings.isChinese ? '退出' : 'Quit';

  static String dockCloseWindow(LicoStrings strings) =>
      strings.isChinese ? '关闭窗口' : 'Close window';

  static String dockKeepInDock(LicoStrings strings) =>
      strings.isChinese ? '在程序坞中保留' : 'Keep in Dock';

  static String dockRemoveFromDock(LicoStrings strings) =>
      strings.isChinese ? '从程序坞移除' : 'Remove from Dock';

  static String dockWaitingDecisions(LicoStrings strings, int count) =>
      strings.isChinese ? '$count 项待决定' : '$count waiting for you';

  static String resizeSidebarLabel(LicoStrings strings) =>
      strings.isChinese ? '调整聊天侧栏宽度' : 'Resize the chat sidebar';
  static String quickSwitcherTooltip(LicoStrings strings) =>
      strings.isChinese ? '快速切换（⌘K）' : 'Quick switcher (⌘K)';
}
