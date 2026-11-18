import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings_base.dart';

/// Plugin window copy: window states, the permission sheet and the sandbox
/// popover.
extension LicoStringsPluginWindow on LicoStrings {
  String get pluginWindowLoading =>
      isChinese ? '正在加载插件…' : 'Loading the plugin…';
  String get pluginWindowNotInstalled =>
      isChinese ? '此插件未安装' : 'This plugin is not installed';
  String get pluginWindowErrorTitle =>
      isChinese ? '插件没能加载出来' : 'The plugin could not load';
  String get pluginWindowErrorMessage => isChinese
      ? '重新加载通常就能恢复。若仍然失败，请在插件中心检查这个插件。'
      : 'Reloading usually fixes this. If it keeps failing, check the plugin '
            'in the Plugin Center.';
  String pluginWindowErrorCode(String code) =>
      isChinese ? '错误代码 $code' : 'Error code $code';
  String get pluginWindowReload => isChinese ? '重新加载' : 'Reload';
  String get pluginWindowOfflineTitle => isChinese ? '当前离线' : 'You are offline';
  String get pluginWindowOfflineMessage => isChinese
      ? '这个插件需要网络连接。恢复连接后重新加载。'
      : 'This plugin needs a network connection. Reload once you are back '
            'online.';
  String get pluginWindowUnsupportedTitle => isChinese
      ? '此设备暂不支持插件窗口'
      : 'Plugin windows are not supported on this device yet';
  String get pluginWindowUnsupportedMessage => isChinese
      ? '插件窗口宿主还没有在这个平台上提供，内置应用不受影响。'
      : 'The plugin window host is not available on this platform yet. '
            'Built-in apps are not affected.';

  String pluginWindowPermissionTitle(String plugin, String capability) =>
      isChinese
      ? '「$plugin」请求使用 $capability'
      : '“$plugin” asks to use $capability';
  String get pluginWindowAllowOnce => isChinese ? '仅此一次' : 'Allow once';
  String get pluginWindowAllowAlways => isChinese ? '始终允许' : 'Always allow';
  String get pluginWindowDeny => isChinese ? '拒绝' : 'Deny';

  String pluginWindowCapabilityLabel(String capability) =>
      capability == pluginClipboardCapability
      ? (isChinese ? '剪贴板' : 'the clipboard')
      : capability;

  String get pluginWindowSandbox => isChinese ? '沙盒' : 'Sandbox';
  String pluginWindowSandboxTitle(String plugin) =>
      isChinese ? '$plugin · 沙盒权限' : '$plugin · Sandbox permissions';
  String get pluginWindowNetwork => isChinese ? '网络' : 'Network';
  String pluginWindowNetworkAllowed(List<String> origins) {
    final hosts = [
      for (final origin in origins) origin.replaceFirst('https://', ''),
    ].join(isChinese ? '、' : ', ');
    return isChinese ? '允许 $hosts' : 'Allows $hosts';
  }

  String get pluginWindowLocalFiles => isChinese ? '本地文件' : 'Local files';
  String get pluginWindowClipboard => isChinese ? '剪贴板' : 'Clipboard';
  String pluginWindowClipboardAccess(PluginClipboardAccess access) =>
      switch (access) {
        PluginClipboardAccess.none => pluginWindowNone,
        PluginClipboardAccess.ask => isChinese ? '每次询问' : 'Ask every time',
        PluginClipboardAccess.allow => isChinese ? '允许' : 'Allowed',
      };
  String get pluginWindowCapabilities =>
      isChinese ? 'LicoUp 能力' : 'LicoUp capabilities';
  String get pluginWindowNone => isChinese ? '无' : 'None';

  String get pluginWindowMore => isChinese ? '更多' : 'More';
  String get pluginWindowPermissionSettings =>
      isChinese ? '权限设置' : 'Permission settings';
  String get pluginWindowClose => isChinese ? '关闭窗口' : 'Close window';
}
