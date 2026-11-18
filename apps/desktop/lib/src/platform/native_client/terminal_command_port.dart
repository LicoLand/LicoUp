import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/terminal_command.dart';

export 'package:licoup/src/contracts/terminal_command.dart';

/// The suffix identifying a link this client owns.
const String _custodyExecutableSuffix =
    '/Contents/Helpers/LicoUpCustody.app/Contents/MacOS/licoup';

/// The production port: filesystem ops against `/usr/local/bin`, escalating to
/// the macOS administrator prompt only when the directory is not writable.
final class DarwinTerminalCommandPort implements TerminalCommandPort {
  const DarwinTerminalCommandPort();

  static const String _binDirectory = '/usr/local/bin';

  @override
  Future<TerminalCommandInspection> inspect() async {
    final link = Link(terminalCommandLinkPath);
    final type = await FileSystemEntity.type(
      terminalCommandLinkPath,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      return const TerminalCommandInspection(
        status: TerminalCommandStatus.notInstalled,
      );
    }
    if (type != FileSystemEntityType.link) {
      return TerminalCommandInspection(
        status: TerminalCommandStatus.occupied,
        occupiedPath: terminalCommandLinkPath,
      );
    }
    final target = await link.target();
    if (!target.endsWith(_custodyExecutableSuffix)) {
      // A foreign symlink (for example a cargo-installed licoup) is occupied,
      // not ours: show where it points.
      return TerminalCommandInspection(
        status: TerminalCommandStatus.occupied,
        occupiedPath: target,
      );
    }
    final exists = await File(target).exists();
    return TerminalCommandInspection(
      status: exists
          ? TerminalCommandStatus.installed
          : TerminalCommandStatus.stale,
      linkTarget: target,
    );
  }

  @override
  Future<bool> canWriteDirectory() async {
    final directory = Directory(_binDirectory);
    if (!await directory.exists()) {
      // /usr/local exists on every macOS install; creating `bin` needs the
      // same privilege as writing inside it.
      return false;
    }
    try {
      final probe = File(p.join(_binDirectory, '.licoup-probe-$pid'));
      await probe.writeAsBytes(const []);
      await probe.delete();
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> install({required String target, required bool privileged}) {
    // ln -sfn repoints an existing owned link in the same single operation.
    final shell =
        'mkdir -p ${_quote(_binDirectory)} && ln -sfn ${_quote(target)} '
        '${_quote(terminalCommandLinkPath)}';
    return privileged ? _runElevated(shell) : _runShell(shell);
  }

  @override
  Future<void> uninstall({required bool privileged}) {
    final shell = 'rm -f ${_quote(terminalCommandLinkPath)}';
    return privileged ? _runElevated(shell) : _runShell(shell);
  }

  Future<void> _runShell(String script) async {
    final result = await Process.run('/bin/sh', ['-c', script]);
    if (result.exitCode != 0) {
      throw StateError('terminal_command_operation_failed');
    }
  }

  Future<void> _runElevated(String script) async {
    final result = await Process.run('/usr/bin/osascript', [
      '-e',
      'do shell script "${_appleScriptQuote(script)}" '
          'with administrator privileges',
    ]);
    // osascript exits non-zero with a "User canceled" error on cancellation;
    // the controller maps that to the distinct cancelled outcome.
    if (result.exitCode != 0) {
      final stderr = '${result.stderr}';
      if (stderr.contains('User canceled')) {
        throw const TerminalCommandCancelledException();
      }
      throw StateError('terminal_command_operation_failed');
    }
  }

  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  static String _appleScriptQuote(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}

/// The canonical bundled `licoup` path a link should point at, derived from
/// the running client executable's app bundle. The GUI executable is `LicoUp`;
/// the custody helper is its only signed `licoup`. A path outside an app
/// bundle resolves nothing.
String? bundledCustodyExecutable(String resolvedExecutable) {
  final normalized = p.normalize(resolvedExecutable);
  if (normalized.endsWith(_custodyExecutableSuffix)) return normalized;
  const marker = '.app/Contents/MacOS/';
  final index = normalized.indexOf(marker);
  if (index < 0) return null;
  final appRoot = normalized.substring(0, index + '.app'.length);
  return '$appRoot/Contents/Helpers/LicoUpCustody.app/Contents/MacOS/licoup';
}
