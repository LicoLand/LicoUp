import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/contracts/user_home_directory.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';

void main() {
  /// Synthetic project directories never exist on the test machine, so presence
  /// is answered by the fixture instead of the filesystem.
  bool syntheticProjectExists(String path) =>
      path.startsWith('/synthetic/workspaces/');

  AgentConversationSession session({
    required String id,
    required String updatedAt,
    String workingDirectory = '',
  }) {
    return AgentConversationSession(
      id: id,
      agentId: 'cursor',
      title: id,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      messages: const [],
      workingDirectory: workingDirectory,
    );
  }

  test('historical cwd prefers the newest usable project path', () {
    final home = userHomeDirectory();
    expect(home, isNotEmpty);

    final chosen = historicalConversationWorkingDirectory([
      session(
        id: 'old',
        updatedAt: '2026-01-01T00:00:00Z',
        workingDirectory: '/synthetic/workspaces/older-project',
      ),
      session(
        id: 'home',
        updatedAt: '2026-06-01T00:00:00Z',
        workingDirectory: home,
      ),
      session(
        id: 'recent',
        updatedAt: '2026-05-01T00:00:00Z',
        workingDirectory: '/synthetic/workspaces/recent-project',
      ),
      session(id: 'empty', updatedAt: '2026-07-01T00:00:00Z'),
    ], directoryExists: syntheticProjectExists);

    expect(chosen, '/synthetic/workspaces/recent-project');
  });

  test('historical cwd is empty when only unbounded roots exist', () {
    final home = userHomeDirectory();
    expect(home, isNotEmpty);

    final chosen = historicalConversationWorkingDirectory([
      session(
        id: 'home',
        updatedAt: '2026-06-01T00:00:00Z',
        workingDirectory: home,
      ),
    ], directoryExists: syntheticProjectExists);

    expect(chosen, isEmpty);
  });

  test('historical cwd skips the client-owned agent-workspace fallback', () {
    final fallback = localConversationWorkingDirectoryFallback(
      agentId: 'cursor',
    );
    expect(fallback, isNotEmpty);
    expect(fallback.endsWith('/.lico-up/agent-workspace'), isTrue);
    expect(
      localConversationWorkingDirectoryFallback(agentId: 'codex'),
      fallback,
    );
    expect(isClientOwnedAgentWorkspace(fallback), isTrue);
    expect(
      isUsableLocalConversationWorkingDirectory(
        fallback,
        directoryExists: syntheticProjectExists,
      ),
      isFalse,
    );

    final chosen = historicalConversationWorkingDirectory([
      session(
        id: 'fallback',
        updatedAt: '2026-07-01T00:00:00Z',
        workingDirectory: fallback,
      ),
      session(
        id: 'project',
        updatedAt: '2026-05-01T00:00:00Z',
        workingDirectory: '/synthetic/workspaces/real-project',
      ),
    ], directoryExists: syntheticProjectExists);

    expect(chosen, '/synthetic/workspaces/real-project');
  });

  test('explicit binds stay admissible without a presence check', () {
    expect(
      isBoundableConversationWorkingDirectory(
        '/synthetic/workspaces/draft-project',
      ),
      isTrue,
    );
    expect(
      isBoundableConversationWorkingDirectory(
        localConversationWorkingDirectoryFallback(agentId: 'cursor'),
      ),
      isFalse,
    );
  });

  test('a recorded project directory that no longer exists is not bindable', () {
    // Agent stores keep whatever directory a turn ran in, including temporary
    // workspaces and projects that have since been deleted or moved. Binding one
    // of those looks bound while the local agent resolves something else.
    expect(
      isUsableLocalConversationWorkingDirectory(
        '/synthetic/workspaces/deleted-project',
        directoryExists: (_) => false,
      ),
      isFalse,
    );
    expect(
      isBoundableConversationWorkingDirectory(
        '/synthetic/workspaces/deleted-project',
      ),
      isTrue,
    );
    expect(
      isUsableLocalConversationWorkingDirectory(
        '/synthetic/workspaces/live-project',
        directoryExists: syntheticProjectExists,
      ),
      isTrue,
    );
  });

  test('automatic fallback does not stat personal or network locations', () {
    const home = '/synthetic-home';
    const environment = {'HOME': home};
    expect(
      isAutomaticFilesystemProbeDenied(
        '$home/Desktop/project',
        environment: environment,
      ),
      isTrue,
    );
    expect(
      isAutomaticFilesystemProbeDenied(
        '/Volumes'
        '/team-share/repo',
        environment: environment,
      ),
      isTrue,
    );
    expect(
      isAutomaticFilesystemProbeDenied(
        '/synthetic/workspaces/live-project',
        environment: environment,
      ),
      isFalse,
    );
    expect(
      isUsableLocalConversationWorkingDirectory(
        '$home/Desktop/project',
        environment: environment,
        directoryExists: (_) => true,
        automaticFallback: true,
      ),
      isFalse,
    );
    expect(
      isUsableLocalConversationWorkingDirectory(
        '/Volumes'
        '/team-share/repo',
        environment: environment,
        directoryExists: (_) => true,
      ),
      isTrue,
      reason: 'an explicit composer bind may use a mounted project',
    );
    expect(
      isBoundableConversationWorkingDirectory(
        '$home/Desktop/project',
        environment: environment,
      ),
      isTrue,
    );
    const dataPrefix =
        '/System'
        '/Volumes'
        '/Data';
    expect(
      isAutomaticFilesystemProbeDenied(
        '$dataPrefix$home/Documents/project',
        environment: environment,
      ),
      isTrue,
    );
    expect(
      isAutomaticFilesystemProbeDenied(
        '$home/Music/album',
        environment: environment,
      ),
      isTrue,
    );
    expect(
      isUnboundedLocalAgentWorkspace(
        '$dataPrefix$home/Pictures',
        environment: environment,
      ),
      isTrue,
    );
  });

  test('historical cwd skips missing workspaces', () {
    final chosen = historicalConversationWorkingDirectory([
      session(
        id: 'temp',
        updatedAt: '2026-07-01T00:00:00Z',
        workingDirectory: '/fixture-root/ephemeral/gone/workspace',
      ),
      session(
        id: 'project',
        updatedAt: '2026-05-01T00:00:00Z',
        workingDirectory: '/synthetic/workspaces/live-project',
      ),
    ], directoryExists: syntheticProjectExists);

    expect(chosen, '/synthetic/workspaces/live-project');
  });
}
