import 'dart:io' show Platform, Process;

import 'package:licoup/src/contracts/directory_opener.dart';

class RuntimePlatformBridge implements DirectoryOpener {
  const RuntimePlatformBridge();

  bool get isAndroid => Platform.isAndroid;
  bool get isIos => Platform.isIOS;
  bool get isMacos => Platform.isMacOS;
  bool get isWindows => Platform.isWindows;
  bool get isMobileClientRuntime => isAndroid || isIos;

  String? environmentValue(String key) => Platform.environment[key];

  String get localHostname {
    final value = Platform.localHostname.trim();
    return value.isEmpty ? 'LicoUp' : value;
  }

  @override
  Future<DirectoryOpenResult> openDirectory(String directoryPath) async {
    final command = isMacos
        ? 'open'
        : isWindows
        ? 'explorer'
        : 'xdg-open';
    final result = await Process.run(command, [directoryPath]);
    return DirectoryOpenResult(exitCode: result.exitCode);
  }
}
