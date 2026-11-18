import 'dart:io';

import 'package:licoup/src/platform/native_client/terminal_command_port.dart';

/// Result of one user action on the terminal command entry.
enum TerminalCommandActionResult {
  /// The link now points at this app's bundled binary.
  installed,

  /// The owned link was removed.
  uninstalled,

  /// The destination holds a foreign entry: nothing was changed, and the
  /// blocking path is reported.
  occupied,

  /// The user dismissed the administrator prompt: nothing was changed and the
  /// outcome is not an error.
  cancelled,

  /// The write failed for another reason.
  failed,

  /// Nothing existed at the destination to remove.
  notInstalled,

  /// The feature is unavailable off macOS or without a bundled binary.
  unavailable,
}

/// Application controller for the macOS "install terminal command" entry.
///
/// The decision table is stateless: ownership is re-checked on every action
/// immediately before anything writes, so a link another app created between
/// the status read and the write is never touched.
final class TerminalCommandController {
  TerminalCommandController({
    TerminalCommandPort? port,
    String? Function()? bundledTarget,
  }) : _port = port ?? const DarwinTerminalCommandPort(),
       _bundledTarget =
           bundledTarget ??
           (() => bundledCustodyExecutable(
             File(Platform.resolvedExecutable).path,
           ));

  final TerminalCommandPort _port;
  final String? Function() _bundledTarget;

  /// The canonical bundled `licoup` this client's link must point at, or null
  /// when the client is not running inside its custody bundle. The resolver
  /// override exists for tests, which run outside an app bundle.
  String? get canonicalTarget => _bundledTarget();

  bool get supported => Platform.isMacOS && canonicalTarget != null;

  Future<TerminalCommandInspection> inspect() => _port.inspect();

  /// Install or repoint the link at this app's bundled binary.
  Future<(TerminalCommandActionResult, String?)> install() async {
    final target = canonicalTarget;
    if (target == null || !File(target).existsSync()) {
      return (TerminalCommandActionResult.unavailable, null);
    }
    // Re-check ownership immediately before writing: an occupied destination
    // (a foreign file or a foreign symlink, such as a cargo-installed licoup)
    // is refused with its path and never changed.
    final current = await _port.inspect();
    if (current.status == TerminalCommandStatus.occupied) {
      return (TerminalCommandActionResult.occupied, current.occupiedPath);
    }
    final privileged = !(await _port.canWriteDirectory());
    try {
      await _port.install(target: target, privileged: privileged);
      return (TerminalCommandActionResult.installed, null);
    } on Object catch (error) {
      return (
        terminalCommandCancelled(error)
            ? TerminalCommandActionResult.cancelled
            : TerminalCommandActionResult.failed,
        null,
      );
    }
  }

  /// Remove the link only while it is ours. A foreign entry is refused with
  /// its path and nothing is changed; an absent destination is a no-op.
  Future<(TerminalCommandActionResult, String?)> uninstall() async {
    if (canonicalTarget == null) {
      return (TerminalCommandActionResult.unavailable, null);
    }
    final current = await _port.inspect();
    if (current.status == TerminalCommandStatus.occupied) {
      return (TerminalCommandActionResult.occupied, current.occupiedPath);
    }
    if (current.status == TerminalCommandStatus.notInstalled) {
      return (TerminalCommandActionResult.notInstalled, null);
    }
    final privileged = !(await _port.canWriteDirectory());
    try {
      await _port.uninstall(privileged: privileged);
      return (TerminalCommandActionResult.uninstalled, null);
    } on Object catch (error) {
      return (
        terminalCommandCancelled(error)
            ? TerminalCommandActionResult.cancelled
            : TerminalCommandActionResult.failed,
        null,
      );
    }
  }
}
