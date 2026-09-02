import 'package:licoup/src/application/features/settings/controller/client_update_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_update_gateway.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'download verifies internally so apply can run without chrome steps',
    () async {
      final gateway = _FakeClientUpdateGateway();
      final updates = <ClientUpdateStatusUpdate>[];
      final controller = ClientUpdateController(
        gateway: gateway,
        agentService: _NoopAgentCommandRunner(),
        onStatus: updates.add,
      );
      addTearDown(controller.dispose);

      await controller.verify();
      expect(updates.last.errorCode, 'client_update_verify_invalid');

      await controller.check(
        manifestPath: ' manifest.json ',
        publicKeysPath: ' keys.json ',
      );
      await controller.download(sourcePath: 'client-update.bin');

      expect(gateway.calls, ['status', 'check', 'download', 'verify']);
      expect(controller.manifestPath, 'manifest.json');
      expect(controller.publicKeysPath, 'keys.json');
      expect(controller.artifactReceiptId, startsWith('sha256:'));
      expect(controller.status.phase, ClientUpdatePhase.verified);
      expect(controller.canDownloadUpdate, isFalse);
      expect(controller.canApplyUpdate, isTrue);
      expect(controller.busy, isFalse);
    },
  );

  test('signed update slice fails closed with stable error codes', () async {
    final gateway = _FakeClientUpdateGateway()..failCheck = true;
    final updates = <ClientUpdateStatusUpdate>[];
    final controller = ClientUpdateController(
      gateway: gateway,
      agentService: _NoopAgentCommandRunner(),
      onStatus: updates.add,
    );
    addTearDown(controller.dispose);

    await controller.check(
      manifestPath: 'manifest.json',
      publicKeysPath: 'keys.json',
    );

    expect(controller.status.phase, ClientUpdatePhase.failed);
    expect(controller.status.errorCode, 'client_update_check_failed');
    expect(controller.status.updateAvailable, isFalse);
    expect(controller.canDownloadUpdate, isFalse);
    expect(controller.canApplyUpdate, isFalse);
    expect(updates.last.errorCode, 'client_update_check_failed');
  });

  test('signed update slice rejects a substituted artifact receipt', () async {
    final gateway = _FakeClientUpdateGateway()..mismatchDownloadReceipt = true;
    final updates = <ClientUpdateStatusUpdate>[];
    final controller = ClientUpdateController(
      gateway: gateway,
      agentService: _NoopAgentCommandRunner(),
      onStatus: updates.add,
    );
    addTearDown(controller.dispose);

    await controller.check(
      manifestPath: 'manifest.json',
      publicKeysPath: 'keys.json',
    );
    await controller.download(sourcePath: 'client-update.bin');

    expect(controller.status.phase, ClientUpdatePhase.failed);
    expect(controller.status.errorCode, 'client_update_download_failed');
    expect(controller.canApplyUpdate, isFalse);
    expect(updates.last.errorCode, 'client_update_download_failed');
  });

  test('github source check-download-apply uses the running version', () async {
    final gateway = _FakeClientUpdateGateway();
    final updates = <ClientUpdateStatusUpdate>[];
    var exited = false;
    final controller = ClientUpdateController(
      gateway: gateway,
      agentService: _NoopAgentCommandRunner(),
      onStatus: updates.add,
      dataDirectory: () async => '/data/lico',
    );
    addTearDown(controller.dispose);

    await controller.hydrateIdentity();
    expect(controller.status.runningVersion, '1.0.0');
    expect(controller.sourceAddress, kClientUpdateGithubReleasesUrl);

    await controller.checkGithub(repo: kClientUpdateGithubRepo);
    expect(controller.source, 'github');
    expect(controller.status.phase, ClientUpdatePhase.updateAvailable);
    expect(controller.status.availableVersion, '1.1.0');
    expect(controller.status.runningVersion, '1.0.0');
    expect(controller.canDownloadUpdate, isTrue);
    expect(controller.canApplyUpdate, isFalse);
    expect(
      controller.sourceAddress,
      'https://github.com/LicoLand/LicoUp/releases/tag/v1.1.0',
    );

    await controller.downloadGithub();
    expect(controller.status.phase, ClientUpdatePhase.verified);
    expect(controller.canDownloadUpdate, isFalse);
    expect(controller.canApplyUpdate, isTrue);

    await controller.applyThenExit(() => exited = true);
    expect(controller.status.phase, ClientUpdatePhase.applied);
    expect(exited, isTrue);
    expect(gateway.lastApplyDataRoot, '/data/lico');
    expect(gateway.calls, ['status', 'check', 'download', 'verify', 'apply']);
  });

  test('nightly can select stable and clears the previous artifact', () async {
    final gateway = _FakeClientUpdateGateway();
    final controller = ClientUpdateController(
      gateway: gateway,
      agentService: _NoopAgentCommandRunner(),
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);

    await controller.hydrateIdentity();
    controller.selectTargetReleaseTrack(ReleaseTrack.stable);

    expect(controller.status.targetReleaseTrack, ReleaseTrack.stable);
    expect(controller.status.phase, ClientUpdatePhase.idle);

    await controller.checkGithub();
    expect(gateway.lastCheckTargetReleaseTrack, 'stable');
    expect(controller.status.updateAvailable, isTrue);
    expect(controller.artifactReceiptId, isNotEmpty);

    controller.selectTargetReleaseTrack(ReleaseTrack.nightly);
    expect(controller.status.targetReleaseTrack, ReleaseTrack.nightly);
    expect(controller.status.phase, ClientUpdatePhase.idle);
    expect(controller.status.updateAvailable, isFalse);
    expect(controller.status.availableVersion, isEmpty);
    expect(controller.artifactReceiptId, isEmpty);
    expect(controller.canDownloadUpdate, isFalse);
    expect(controller.canApplyUpdate, isFalse);
  });

  test('applyThenExit only exits after the applied phase confirms', () async {
    final gateway = _FakeClientUpdateGateway();
    final updates = <ClientUpdateStatusUpdate>[];
    final controller = ClientUpdateController(
      gateway: gateway,
      agentService: _NoopAgentCommandRunner(),
      onStatus: updates.add,
    );
    addTearDown(controller.dispose);

    var exited = false;
    await controller.applyThenExit(() => exited = true);
    expect(exited, isFalse);
    expect(updates.last.errorCode, 'client_update_apply_invalid');

    await controller.checkGithub();
    await controller.downloadGithub();
    await controller.applyThenExit(() => exited = true);
    expect(exited, isTrue);
    expect(controller.status.phase, ClientUpdatePhase.applied);
  });

  test(
    'failed check keeps the running version and does not enable download',
    () async {
      final gateway = _FakeClientUpdateGateway()..failCheck = true;
      final controller = ClientUpdateController(
        gateway: gateway,
        agentService: _NoopAgentCommandRunner(),
        onStatus: (_) {},
      );
      addTearDown(controller.dispose);

      await controller.hydrateIdentity();
      expect(controller.status.runningVersion, '1.0.0');
      expect(controller.status.phase, ClientUpdatePhase.idle);

      await controller.checkGithub();
      expect(controller.status.phase, ClientUpdatePhase.failed);
      expect(controller.status.errorCode, 'client_update_check_failed');
      expect(controller.status.runningVersion, '1.0.0');
      expect(controller.status.updateAvailable, isFalse);
      expect(controller.canCheckUpdate, isTrue);
      expect(controller.canDownloadUpdate, isFalse);
      expect(controller.canApplyUpdate, isFalse);
    },
  );
}

final class _FakeClientUpdateGateway implements ClientUpdateGateway {
  final List<String> calls = [];
  bool failCheck = false;
  bool mismatchDownloadReceipt = false;
  String lastApplyDataRoot = '';
  String lastCheckTargetReleaseTrack = '';

  ClientUpdateStatus _status(ClientUpdatePhase phase) => ClientUpdateStatus(
    phase: phase,
    runningVersion: '1.0.0',
    runningReleaseTrack: ReleaseTrack.nightly,
    targetReleaseTrack: ReleaseTrack.stable,
    availableVersion: '1.1.0',
    updateAvailable: phase == ClientUpdatePhase.updateAvailable,
    artifactSha256: 'sha256:artifact',
    artifactReceiptId: 'sha256:receipt',
    manifestSha256: 'sha256:manifest',
    targetId: 'test-target',
    githubReleaseUrl: 'https://github.com/LicoLand/LicoUp/releases/tag/v1.1.0',
  );

  void _record(String call) {
    calls.add(call);
  }

  @override
  Future<ClientUpdateStatus> apply({
    required AgentCommandRunner agentService,
    required bool execute,
    String manifestPath = '',
    String publicKeysPath = '',
    String revocationPath = '',
    String source = 'local',
    String repo = kClientUpdateGithubRepo,
    String stagingRoot = '',
    String stateRoot = '',
    String dataRoot = '',
  }) async {
    _record('apply');
    lastApplyDataRoot = dataRoot;
    return _status(
      execute ? ClientUpdatePhase.applied : ClientUpdatePhase.applyPlanned,
    );
  }

  @override
  Future<ClientUpdateStatus> check({
    required AgentCommandRunner agentService,
    String manifestPath = '',
    String publicKeysPath = '',
    String targetReleaseTrack = '',
    String revocationPath = '',
    String source = 'local',
    String repo = kClientUpdateGithubRepo,
    String stagingRoot = '',
    String stateRoot = '',
  }) async {
    _record('check');
    lastCheckTargetReleaseTrack = targetReleaseTrack;
    if (failCheck) throw StateError('check_failed');
    return _status(ClientUpdatePhase.updateAvailable);
  }

  @override
  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    String manifestPath = '',
    String publicKeysPath = '',
    String sourcePath = '',
    String revocationPath = '',
    String source = 'local',
    String repo = kClientUpdateGithubRepo,
    String stagingRoot = '',
    String stateRoot = '',
  }) async {
    _record('download');
    final status = _status(ClientUpdatePhase.downloaded);
    return mismatchDownloadReceipt
        ? status.copyWith(artifactReceiptId: 'sha256:substituted')
        : status;
  }

  @override
  Future<ClientUpdateStatus> status({
    required AgentCommandRunner agentService,
    String targetReleaseTrack = '',
    String source = 'local',
    String repo = kClientUpdateGithubRepo,
    String stateRoot = '',
  }) async {
    _record('status');
    return const ClientUpdateStatus(
      phase: ClientUpdatePhase.idle,
      runningVersion: '1.0.0',
      runningReleaseTrack: ReleaseTrack.nightly,
      targetReleaseTrack: ReleaseTrack.nightly,
    );
  }

  @override
  Future<ClientUpdateStatus> verify({
    required AgentCommandRunner agentService,
    String manifestPath = '',
    String publicKeysPath = '',
    String revocationPath = '',
    String source = 'local',
    String repo = kClientUpdateGithubRepo,
    String stagingRoot = '',
    String stateRoot = '',
  }) async {
    _record('verify');
    return _status(ClientUpdatePhase.verified);
  }
}

final class _NoopAgentCommandRunner implements AgentCommandRunner {
  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => const {};

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
