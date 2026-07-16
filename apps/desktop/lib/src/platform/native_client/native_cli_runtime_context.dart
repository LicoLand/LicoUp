import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

/// Resolves the native sidecar and its bounded, client-owned environment.
class NativeCliRuntimeContext implements NativeCliProcessContext {
  NativeCliRuntimeContext({
    Future<String> Function()? dataDirectory,
    NativeResolveCliBinary? resolveCliBinary,
    NativeStartCliExecutable? startCliExecutable,
    this.requestTimeout = const Duration(seconds: 150),
  }) : _dataDirectory = dataDirectory,
       _resolveCliBinaryOverride = resolveCliBinary,
       _startCliExecutable = startCliExecutable ?? _defaultStartCliExecutable;

  final Future<String> Function()? _dataDirectory;
  final NativeResolveCliBinary? _resolveCliBinaryOverride;
  final NativeStartCliExecutable _startCliExecutable;

  @override
  final Duration requestTimeout;

  static Future<Process> _defaultStartCliExecutable(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) {
    return Process.start(executable, arguments, environment: environment);
  }

  @override
  Future<File?> resolveCliBinary() async {
    final overrideResolver = _resolveCliBinaryOverride;
    if (overrideResolver != null) {
      return overrideResolver();
    }

    final suffix = Platform.isWindows ? '.exe' : '';
    final explicitBinary = Platform.environment['LICO_CLIENT_PATH'];
    final cargoTargetDirectory = Platform.environment['CARGO_TARGET_DIR'];
    final candidates = <String>[
      if (explicitBinary != null && explicitBinary.trim().isNotEmpty)
        explicitBinary.trim(),
      if (cargoTargetDirectory != null &&
          cargoTargetDirectory.trim().isNotEmpty)
        p.join(cargoTargetDirectory.trim(), 'debug', 'lico-client$suffix'),
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        'lico-client$suffix',
      ),
      p.join(
        Directory.current.path,
        'build',
        'crates',
        'lico-client-native',
        'target',
        'debug',
        'lico-client$suffix',
      ),
      p.join(Directory.current.path, 'target', 'debug', 'lico-client$suffix'),
    ];
    for (final candidate in candidates) {
      final file = File(p.normalize(candidate));
      if (await file.exists()) {
        return file;
      }
    }
    return null;
  }

  @override
  Future<Map<String, String>?> buildEnvironment() async {
    final environment = <String, String>{
      ..._macOSLocalAuthenticationEnvironment(),
    };
    final dataDirectory = _dataDirectory;
    if (dataDirectory != null) {
      final directory = await dataDirectory();
      environment['LICOARC_PORTABLE_DIR'] = directory;
    }
    return environment.isEmpty ? null : environment;
  }

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) {
    return _startCliExecutable(executable, arguments, environment);
  }

  Map<String, String> _macOSLocalAuthenticationEnvironment() {
    if (!Platform.isMacOS) {
      return const {};
    }
    return const {
      'LICO_SECURE_MESH_MACOS_USER_PRESENCE_REQUIRED': 'production',
    };
  }
}
