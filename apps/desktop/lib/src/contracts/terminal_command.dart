/// Destination of the macOS "install terminal command" feature: the public
/// `licoup` link every shell resolves. Only the bundled custody executable may
/// become its target; nothing else is ever written there.
const String terminalCommandLinkPath = '/usr/local/bin/licoup';

/// What `/usr/local/bin/licoup` currently is.
enum TerminalCommandStatus {
  /// Nothing exists at the destination.
  notInstalled,

  /// Our symlink, pointing at this app's bundled binary.
  installed,

  /// Our symlink, pointing somewhere else or at a vanished target.
  stale,

  /// A foreign file or foreign symlink occupies the destination. The occupied
  /// path is reported to the user; nothing is changed.
  occupied,
}

final class TerminalCommandInspection {
  const TerminalCommandInspection({
    required this.status,
    this.occupiedPath,
    this.linkTarget,
  });

  final TerminalCommandStatus status;

  /// The foreign target shown to the user when [status] is `occupied`.
  final String? occupiedPath;

  /// The current symlink target when [status] is `installed` or `stale`.
  final String? linkTarget;
}

/// The outcome of one install or uninstall attempt.
enum TerminalCommandOutcome { done, occupiedRefused, cancelled, failed }

/// Filesystem and privileged-exec surface for the terminal command feature.
/// Injectable so tests run the full decision table without touching
/// `/usr/local/bin`.
abstract class TerminalCommandPort {
  Future<TerminalCommandInspection> inspect();

  /// Creates the destination directory when missing and (re)points the link.
  /// [privileged] asks for the administrator prompt path.
  Future<void> install({required String target, required bool privileged});

  /// Removes the link.
  Future<void> uninstall({required bool privileged});

  /// Whether the destination directory is writable without elevation.
  Future<bool> canWriteDirectory();
}

/// Raised when the user dismisses the administrator prompt: a distinct,
/// non-error outcome the controller reports as `cancelled`.
final class TerminalCommandCancelledException implements Exception {
  const TerminalCommandCancelledException();
}

bool terminalCommandCancelled(Object error) =>
    error is TerminalCommandCancelledException;
