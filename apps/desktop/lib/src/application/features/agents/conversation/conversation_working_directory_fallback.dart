import 'dart:io' show Platform;

import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

/// Directory holding the client-owned default workspace of each local agent,
/// relative to the LicoUp state root. The native client owns the same layout and
/// re-resolves it before every local turn.
const clientAgentWorkspaceDirectoryName = 'agent-workspaces';

/// User home directory, used to render an absolute path as `~/...`.
String userHomeDirectory({Map<String, String>? environment}) {
  final resolved = environment ?? Platform.environment;
  return (resolved['HOME'] ?? resolved['USERPROFILE'] ?? '').trim();
}

/// Most recent usable project path recorded on [sessions], newest first.
///
/// Skips empty paths, unbounded personal roots (home, Movies, Pictures, …), and
/// the client-owned `agent-workspaces` fallback. That fallback is only a last
/// resort for process start — it must not masquerade as a conversation's
/// historical project directory after a prior turn wrote it onto the session.
String historicalConversationWorkingDirectory(
  Iterable<AgentConversationSession> sessions, {
  Map<String, String>? environment,
}) {
  for (final session in sortConversationSessionsByUpdatedAt(
    List<AgentConversationSession>.of(sessions),
  )) {
    final directory = session.workingDirectory.trim();
    if (!isUsableLocalConversationWorkingDirectory(
      directory,
      environment: environment,
    )) {
      continue;
    }
    return directory;
  }
  return '';
}

/// Whether [path] is a concrete project directory the client may treat as a
/// conversation's own working directory (absolute, non-empty, not an unbounded
/// personal root, and not the client-owned agent-workspaces fallback).
bool isUsableLocalConversationWorkingDirectory(
  String path, {
  Map<String, String>? environment,
}) {
  final normalized = path.trim();
  return normalized.isNotEmpty &&
      !isUnboundedLocalAgentWorkspace(normalized, environment: environment) &&
      !isClientOwnedAgentWorkspace(normalized, environment: environment);
}

/// Whether [path] is under the LicoUp-owned `agent-workspaces` tree. That tree
/// is a safe send fallback, not a project the user (or Cursor history) chose.
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
  final root = p.normalize(
    p.join(
      home,
      PortableDataRoot.homeStateDirectoryName,
      clientAgentWorkspaceDirectoryName,
    ),
  );
  return p.equals(normalized, root) || p.isWithin(root, normalized);
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
    PortableDataRoot.homeStateDirectoryName,
    clientAgentWorkspaceDirectoryName,
    clientAgentWorkspaceSegment(agentId),
  );
}

/// Single stable path element for one agent identifier.
String clientAgentWorkspaceSegment(String agentId) {
  final segment = agentId
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return segment.isEmpty ? 'agent' : segment;
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
