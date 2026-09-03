import 'package:licoup/src/backend/features/settings/services/client_update_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'update service binds every artifact phase to signed metadata',
    () async {
      final runner = _RecordingCommandRunner();
      const service = ClientUpdateService();

      await service.download(
        agentService: runner,
        manifestPath: 'manifest.json',
        publicKeysPath: 'keys.json',
        sourcePath: 'artifact.bin',
        revocationPath: 'revocation.json',
      );
      await service.verify(
        agentService: runner,
        manifestPath: 'manifest.json',
        publicKeysPath: 'keys.json',
        revocationPath: 'revocation.json',
      );
      await service.apply(
        agentService: runner,
        execute: false,
        manifestPath: 'manifest.json',
        publicKeysPath: 'keys.json',
        revocationPath: 'revocation.json',
        dataRoot: '/data/lico',
      );

      expect(runner.calls, hasLength(3));
      for (final args in runner.calls) {
        expect(args, containsAll(['--manifest-path', 'manifest.json']));
        expect(args, containsAll(['--public-keys-path', 'keys.json']));
        expect(args, isNot(contains('--target-release-track')));
        expect(args, containsAll(['--revocation-path', 'revocation.json']));
        expect(args, containsAll(['--source', 'local']));
        expect(args, isNot(contains('--staged-file-name')));
        expect(args, isNot(contains('--sha256')));
        expect(args, isNot(contains('--size')));
      }
      expect(runner.calls[0], containsAll(['--source-path', 'artifact.bin']));
      expect(runner.calls[1], isNot(contains('--source-path')));
      expect(runner.calls[2], containsAll(['--execute', 'false']));
      expect(runner.calls[0], isNot(contains('--data-root')));
      expect(runner.calls[1], isNot(contains('--data-root')));
      expect(runner.calls[2], containsAll(['--data-root', '/data/lico']));
    },
  );

  test(
    'github source binds repo and roots without local manifest files',
    () async {
      final runner = _RecordingCommandRunner();
      const service = ClientUpdateService();

      await service.check(
        agentService: runner,
        source: 'github',
        repo: 'LicoLand/LicoUp',
        stagingRoot: '/data/client-update-staging',
        stateRoot: '/data/client-update-state',
      );
      await service.download(
        agentService: runner,
        source: 'github',
        repo: 'LicoLand/LicoUp',
        stagingRoot: '/data/client-update-staging',
        stateRoot: '/data/client-update-state',
      );
      await service.apply(
        agentService: runner,
        execute: true,
        source: 'github',
        repo: 'LicoLand/LicoUp',
        stagingRoot: '/data/client-update-staging',
        stateRoot: '/data/client-update-state',
        dataRoot: '/data/lico',
      );
      expect(runner.calls, hasLength(3));
      for (final args in runner.calls) {
        expect(args, containsAll(['--source', 'github']));
        expect(args, containsAll(['--repo', 'LicoLand/LicoUp']));
        expect(
          args,
          containsAll(['--staging-root', '/data/client-update-staging']),
        );
        expect(
          args,
          containsAll(['--state-root', '/data/client-update-state']),
        );
        expect(args, isNot(contains('--manifest-path')));
        expect(args, isNot(contains('--public-keys-path')));
        expect(args, isNot(contains('--target-release-track')));
      }
      expect(runner.calls[2], containsAll(['--execute', 'true']));
      expect(runner.calls[0], isNot(contains('--data-root')));
      expect(runner.calls[1], isNot(contains('--data-root')));
      expect(runner.calls[2], containsAll(['--data-root', '/data/lico']));
    },
  );
}

final class _RecordingCommandRunner implements AgentCommandRunner {
  final List<List<String>> calls = [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List<String>.of(args));
    return const {
      'phase': 'verified',
      'runningReleaseTrack': 'nightly',
      'targetReleaseTrack': 'stable',
      'artifactSha256': 'sha256:artifact',
      'artifactReceipt': {
        'receiptId': 'sha256:receipt',
        'manifestSha256': 'sha256:manifest',
        'targetId': 'test-target',
        'sha256': 'sha256:artifact',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async => const {};

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
