import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Resolves the native sidecar and its bounded, client-owned environment.
class NativeCliRuntimeContext
    implements NativeCliProcessContext, NativeCliDataHomeMutationContext {
  NativeCliRuntimeContext({
    Future<String> Function()? dataDirectory,
    Future<DataHomeSelection> Function()? dataHomeSelection,
    NativeResolveCliBinary? resolveCliBinary,
    NativeStartCliExecutable? startCliExecutable,
    this.requestTimeout = const Duration(seconds: 150),
  }) : _dataDirectory = dataDirectory,
       _dataHomeSelection = dataHomeSelection,
       _resolveCliBinaryOverride = resolveCliBinary,
       _startCliExecutable = startCliExecutable ?? _defaultStartCliExecutable;

  final Future<String> Function()? _dataDirectory;
  final Future<DataHomeSelection> Function()? _dataHomeSelection;
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
  /// bundled helper executable is `licoup-cli`; the sibling `licoup` inside an app
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
    final executableDirectory = File(executablePath).parent.path;
    // An installed app bundle must use its app-like custody helper. Developer CLI and
    // cargo overlays leak into `open` from an Agent shell and can outlive the
    // exact installed product binary.
    final insideAppBundle = executablePath.contains('.app/Contents/MacOS/');
    if (insideAppBundle) {
      final appRoot = p.normalize(p.join(executableDirectory, '..', '..'));
      final helper = File(
        p.join(
          appRoot,
          'Contents',
          'Helpers',
          'LicoUpCustody.app',
          'Contents',
          'MacOS',
          'licoup-cli',
        ),
      );
      if (!await helper.exists()) return null;
      final canonical = await _canonicalPath(helper);
      final canonicalApp = await Directory(appRoot).resolveSymbolicLinks();
      if (p.equals(canonical, selfPath) ||
          !p.isWithin(canonicalApp, canonical)) {
        return null;
      }
      return File(canonical);
    }
    final explicitBinary = environment['LICO_CLIENT_PATH'];
    final cargoTargetDirectory = environment['CARGO_TARGET_DIR'];
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
    final environment = _baseEnvironment();
    final dataHomeSelection = _dataHomeSelection;
    if (dataHomeSelection != null) {
      final selection = await dataHomeSelection();
      environment['LICOUP_HOME'] = switch (selection.source) {
        DataHomeSelectionSource.explicitEnvironment ||
        DataHomeSelectionSource.legacyEnvironment => selection.path,
        _ => '',
      };
      // A parent process may have launched with an older alias. Blank both
      // variables when the selection comes from the locator/default so child
      // CLI processes preserve that same boot authority.
      environment['LICOUP_PORTABLE_DIR'] = '';
      return environment;
    }
    final dataDirectory = _dataDirectory;
    if (dataDirectory != null) {
      final directory = await dataDirectory();
      environment['LICOUP_HOME'] = directory;
    }
    return environment.isEmpty ? null : environment;
  }

  @override
  Future<Map<String, String>?> buildDataHomeMutationEnvironment() async {
    final environment = _baseEnvironment();
    return environment.isEmpty ? null : environment;
  }

  Map<String, String> _baseEnvironment() {
    final environment = <String, String>{
      ..._macOSLocalAuthenticationEnvironment(),
      'LICOUP_CLIENT_PID': '$pid',
    };
    final executablePath = Platform.environment['PATH']?.trim() ?? '';
    if (executablePath.isNotEmpty && executablePath.length <= 32 * 1024) {
      // Process APIs normally inherit the parent environment, but desktop app
      // launch contexts are platform-dependent. Preserve PATH explicitly once
      // an environment overlay is required so the bundled sidecar can discover
      // the same local agent executables as the product process.
      environment['PATH'] = executablePath;
    }
    return environment;
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
