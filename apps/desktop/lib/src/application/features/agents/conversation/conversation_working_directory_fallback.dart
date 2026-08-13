import 'dart:io' as io show Directory, Platform;

import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:path/path.dart' as p;

const _clientHomeStateDirectoryName = '.lico-up';

/// Client-owned default workspace under the LicoUp state root. Shared by every
/// local agent — not partitioned by main-agent id. The native client owns the
/// same layout and re-resolves it before every local turn.
const clientAgentWorkspaceDirectoryName = 'agent-workspace';

/// Retired plural tree from the per-agent workspace layout. Still treated as
/// client-owned so historical session cwd values never bind as projects.
const _retiredClientAgentWorkspaceDirectoryName = 'agent-workspaces';

/// User home directory, used to render an absolute path as `~/...`.
String userHomeDirectory({Map<String, String>? environment}) {
  final resolved = environment ?? io.Platform.environment;
  return (resolved['HOME'] ?? resolved['USERPROFILE'] ?? '').trim();
}

/// Most recent usable project path recorded on [sessions], newest first.
///
/// Skips empty paths, unbounded personal roots (home, Movies, Pictures, …), and
/// the client-owned `agent-workspace` fallback. That fallback is only a last
/// resort for process start — it must not masquerade as a conversation's
/// historical project directory after a prior turn wrote it onto the session.
String historicalConversationWorkingDirectory(
  Iterable<AgentConversationSession> sessions, {
  Map<String, String>? environment,
  bool Function(String path)? directoryExists,
}) {
  for (final session in sortConversationSessionsByUpdatedAt(
    List<AgentConversationSession>.of(sessions),
  )) {
    final directory = session.workingDirectory.trim();
    if (!isUsableLocalConversationWorkingDirectory(
      directory,
      environment: environment,
      directoryExists: directoryExists,
    )) {
      continue;
    }
    return directory;
  }
  return '';
}

/// Whether [path] is an admissible explicit working-directory bind: absolute,
/// non-empty, not an unbounded personal root, and not the client-owned
/// `agent-workspace` fallback. Used for user-chosen next-turn binds (folder
/// picker / draft). Presence is not required here — recorded agent-store
/// directories use [isUsableLocalConversationWorkingDirectory] instead.
bool isBoundableConversationWorkingDirectory(
  String path, {
  Map<String, String>? environment,
}) {
  final normalized = path.trim();
  if (normalized.isEmpty || !p.isAbsolute(normalized)) {
    return false;
  }
  return !isUnboundedLocalAgentWorkspace(
        normalized,
        environment: environment,
      ) &&
      !isClientOwnedAgentWorkspace(normalized, environment: environment);
}

/// Whether [path] is a concrete project directory the client may treat as a
/// conversation's own working directory (absolute, non-empty, not an unbounded
/// personal root, not the client-owned agent-workspace fallback, and still
/// present on this machine).
///
/// Presence matters because an agent store records whatever directory a turn ran
/// in, including temporary workspaces and projects that have since been deleted
/// or moved. Binding one of those looks bound in the UI while the local agent
/// silently resolves a different directory, so a directory that no longer exists
/// is not usable. [directoryExists] is injectable so tests stay filesystem-free.
bool isUsableLocalConversationWorkingDirectory(
  String path, {
  Map<String, String>? environment,
  bool Function(String path)? directoryExists,
}) {
  if (!isBoundableConversationWorkingDirectory(
    path,
    environment: environment,
  )) {
    return false;
  }
  return (directoryExists ?? localProjectDirectoryExists)(path.trim());
}

/// Whether a recorded project directory is still present as a directory.
bool localProjectDirectoryExists(String path) {
  try {
    return io.Directory(path).existsSync();
  } on Object {
    // A path the platform refuses to stat cannot be bound either.
    return false;
  }
}

/// Whether [path] is under the LicoUp-owned `agent-workspace` tree (or the
/// retired per-agent `agent-workspaces` tree). That tree is a safe send
/// fallback, not a project the user (or Cursor history) chose.
bool isClientOwnedAgentWorkspace(
  String path, {
  Map<String, String>? environment,
}) {
  final normalized = p.normalize(path.trim());
  if (normalized.isEmpty || !p.isAbsolute(normalized)) {
    return false;
  }
  final home = userHomeDirectory(environment: environment);
  if (home.isEmpty) {
    return false;
  }
  for (final directoryName in [
    clientAgentWorkspaceDirectoryName,
    _retiredClientAgentWorkspaceDirectoryName,
  ]) {
    final root = p.normalize(
      p.join(home, _clientHomeStateDirectoryName, directoryName),
    );
    if (p.equals(normalized, root) || p.isWithin(root, normalized)) {
      return true;
    }
  }
  return false;
}

/// Effective fallback working directory for a conversation with a locally
/// executed agent when neither the live session, the new-conversation draft,
/// historical session cwd, nor the target supplies one.
///
/// A local agent indexes the directory it is started in, so this stays a small
/// client-owned workspace under the LicoUp state root. The home directory is
/// never the default: handing over the whole personal tree makes every turn walk
/// documents and media libraries the conversation never needs. Returns an empty
/// path when the state root cannot be resolved, which leaves the choice to the
/// native client.
///
/// [agentId] is accepted for call-site compatibility and ignored: the fallback
/// is shared across agents.
String localConversationWorkingDirectoryFallback({
  required String agentId,
  Map<String, String>? environment,
}) {
  final home = userHomeDirectory(environment: environment);
  if (home.isEmpty) {
    return '';
  }
  return p.join(
    home,
    _clientHomeStateDirectoryName,
    clientAgentWorkspaceDirectoryName,
  );
}

/// Whether an explicitly chosen directory is a personal root whose whole tree
/// an agent would index. Only the root itself is rejected, so a project the user
/// selects inside one of them stays usable.
bool isUnboundedLocalAgentWorkspace(
  String path, {
  Map<String, String>? environment,
}) {
  final normalized = p.normalize(path.trim());
  if (normalized.isEmpty || !p.isAbsolute(normalized)) {
    return true;
  }
  if (_mediaLibraryBundleExtensions.contains(
    p.extension(normalized).toLowerCase(),
  )) {
    return true;
  }
  final home = userHomeDirectory(environment: environment);
  if (home.isEmpty) {
    return p.dirname(normalized) == normalized;
  }
  final normalizedHome = p.normalize(home);
  if (p.equals(normalized, normalizedHome) ||
      p.isWithin(normalized, normalizedHome)) {
    return true;
  }
  return p.equals(p.dirname(normalized), normalizedHome) &&
      _personalLibraryRoots.contains(p.basename(normalized).toLowerCase());
}

const _personalLibraryRoots = <String>{
  'applications',
  'desktop',
  'documents',
  'downloads',
  'icloud drive',
  'library',
  'movies',
  'music',
  'onedrive',
  'pictures',
  'public',
  'videos',
};

const _mediaLibraryBundleExtensions = <String>{
  '.photoslibrary',
  '.photolibrary',
  '.imovielibrary',
  '.tvlibrary',
  '.theater',
};
