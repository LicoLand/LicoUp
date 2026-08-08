import 'package:licoup/src/application/features/settings/controller/client_update_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_update_gateway.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'signed update slice enforces check-download-verify-apply order',
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

      await controller.check();
      await controller.download();
      await controller.verify();
      await controller.apply();

      expect(gateway.calls, ['check', 'download', 'verify', 'apply']);
      expect(controller.manifestPath, 'manifest.json');
      expect(controller.publicKeysPath, 'keys.json');
      expect(controller.artifactReceiptId, startsWith('sha256:'));
      expect(controller.status.phase, ClientUpdatePhase.applied);
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

    await controller.check();

    expect(controller.status.phase, ClientUpdatePhase.failed);
    expect(controller.status.errorCode, 'client_update_check_failed');
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

    await controller.check();
    await controller.download();

    expect(controller.status.phase, ClientUpdatePhase.failed);
    expect(controller.status.errorCode, 'client_update_download_failed');
    expect(updates.last.errorCode, 'client_update_download_failed');
  });
}

final class _FakeClientUpdateGateway implements ClientUpdateGateway {
  final List<String> calls = [];
  bool failCheck = false;
  bool mismatchDownloadReceipt = false;

  @override
  Future<bool> autoDownloadOverWifiEnabled() async => true;

  @override
  Future<void> setAutoDownloadOverWifiEnabled(bool enabled) async {}

  @override
  Future<bool> isWifiConnected() async => true;

  ClientUpdateStatus _status(ClientUpdatePhase phase) => ClientUpdateStatus(
    phase: phase,
    currentVersion: '1.0.0',
    channel: 'stable',
    availableVersion: '1.1.0',
    updateAvailable: true,
    artifactSha256: 'sha256:artifact',
    artifactReceiptId: 'sha256:receipt',
    manifestSha256: 'sha256:manifest',
    targetId: 'test-target',
    totalBytes: 123,
  );

  @override
  Future<ClientUpdateStatus> apply({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    calls.add('apply');
    return _status(ClientUpdatePhase.applied);
  }

  @override
  Future<ClientUpdateRemoteCheck> check({
    required AgentCommandRunner agentService,
    String channel = 'stable',
  }) async {
    calls.add('check');
    if (failCheck) throw StateError('check_failed');
    return ClientUpdateRemoteCheck(
      status: _status(ClientUpdatePhase.updateAvailable),
      manifestPath: 'manifest.json',
      publicKeysPath: 'keys.json',
      artifactUrl:
          'https://github.com/LicoLand/LicoUp/releases/download/v1.1.0/LicoUp-macos-arm64-update.tar.gz',
    );
  }

  @override
  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    required String artifactUrl,
    required int expectedBytes,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    calls.add('download');
    final status = _status(ClientUpdatePhase.downloaded);
    return mismatchDownloadReceipt
        ? status.copyWith(artifactReceiptId: 'sha256:substituted')
        : status;
  }

  @override
  Future<ClientUpdateStatus> status({
    required AgentCommandRunner agentService,
    String channel = 'stable',
  }) async => _status(ClientUpdatePhase.upToDate);

  @override
  Future<ClientUpdateStatus> verify({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    calls.add('verify');
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
