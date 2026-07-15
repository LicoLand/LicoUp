import 'dart:convert';
import 'dart:io' show Directory, File, FileMode, Platform, Process;

class RuntimeProcessResult {
  const RuntimeProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

class RuntimePlatformBridge {
  const RuntimePlatformBridge();

  bool get isAndroid => Platform.isAndroid;
  bool get isIos => Platform.isIOS;
  bool get isMacos => Platform.isMacOS;
  bool get isWindows => Platform.isWindows;
  bool get isMobileClientRuntime => isAndroid || isIos;

  String? environmentValue(String key) => Platform.environment[key];

  String get localHostname {
    final value = Platform.localHostname.trim();
    return value.isEmpty ? 'Lico Arc' : value;
  }

  Future<RuntimeProcessResult> openDirectory(String directoryPath) async {
    final command = isMacos
        ? 'open'
        : isWindows
        ? 'explorer'
        : 'xdg-open';
    final result = await Process.run(command, [directoryPath]);
    return RuntimeProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }

  Future<void> writeAndroidMobileProviderSyncDiagnostic(
    Map<String, Object?> payload,
  ) async {
    if (!isAndroid) {
      return;
    }
    final directory = Directory(
      '/sdcard/Android/data/com.liko.arc/files/secure-mesh',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/mobile-provider-sync-diagnostic.jsonl',
    );
    await file.writeAsString(
      '${jsonEncode(payload)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}
