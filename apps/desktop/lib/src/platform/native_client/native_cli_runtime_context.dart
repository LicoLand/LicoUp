import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

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
  Future<File?> resolveCliBinary() {
    return resolveCliBinaryFor(
      executablePath: File(Platform.resolvedExecutable).path,
      environment: Platform.environment,
      workingDirectory: Directory.current.path,
    );
  }

  /// Candidate resolution split from [resolveCliBinary] so tests can pin the
  /// client executable path and environment.
  ///
  /// The resolved binary must never be the client executable itself. The
  /// bundled sidecar is `licoup-cli`; the sibling `licoup` inside an app
  /// bundle is the GUI client. Spawning the client as its own CLI starts a
  /// full new client per command, and each one rescans, snowballing into a
  /// process storm.
  Future<File?> resolveCliBinaryFor({
    required String executablePath,
    required Map<String, String> environment,
    required String workingDirectory,
  }) async {
    final overrideResolver = _resolveCliBinaryOverride;
    if (overrideResolver != null) {
      return overrideResolver();
    }

    final suffix = Platform.isWindows ? '.exe' : '';
    final selfPath = await _canonicalPath(File(executablePath));
    final explicitBinary = environment['LICO_CLIENT_PATH'];
    final cargoTargetDirectory = environment['CARGO_TARGET_DIR'];
    final executableDirectory = File(executablePath).parent.path;
    final candidates = <String>[
      if (explicitBinary != null && explicitBinary.trim().isNotEmpty)
        explicitBinary.trim(),
      if (cargoTargetDirectory != null &&
          cargoTargetDirectory.trim().isNotEmpty)
        p.join(cargoTargetDirectory.trim(), 'debug', 'licoup-cli$suffix'),
      p.join(executableDirectory, 'licoup-cli$suffix'),
      p.join(executableDirectory, 'licoup$suffix'),
      p.join(
        workingDirectory,
        'build',
        'crates',
        'licoup-native',
        'target',
        'debug',
        'licoup-cli$suffix',
      ),
      p.join(workingDirectory, 'target', 'debug', 'licoup-cli$suffix'),
    ];
    for (final candidate in candidates) {
      final normalized = p.normalize(p.absolute(candidate));
      final file = File(normalized);
      if (await file.exists()) {
        final canonical = await _canonicalPath(file);
        if (!p.equals(canonical, selfPath)) {
          return File(canonical);
        }
      }
    }
    return null;
  }

  Future<String> _canonicalPath(File file) async {
    try {
      return p.normalize(await file.resolveSymbolicLinks());
    } on FileSystemException {
      return p.normalize(p.absolute(file.path));
    }
  }

  @override
  Future<Map<String, String>?> buildEnvironment() async {
    final environment = <String, String>{
      ..._macOSLocalAuthenticationEnvironment(),
    };
    final executablePath = Platform.environment['PATH']?.trim() ?? '';
    if (executablePath.isNotEmpty && executablePath.length <= 32 * 1024) {
      // Process APIs normally inherit the parent environment, but desktop app
      // launch contexts are platform-dependent. Preserve PATH explicitly once
      // an environment overlay is required so the bundled sidecar can discover
      // the same local agent executables as the product process.
      environment['PATH'] = executablePath;
    }
    final dataDirectory = _dataDirectory;
    if (dataDirectory != null) {
      final directory = await dataDirectory();
      environment['LICOUP_PORTABLE_DIR'] = directory;
    }
    return environment.isEmpty ? null : environment;
  }

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    if (mode != ProcessStartMode.normal) {
      return Process.start(
        executable,
        arguments,
        environment: environment,
        mode: mode,
      );
    }
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
