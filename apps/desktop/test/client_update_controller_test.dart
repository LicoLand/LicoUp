import 'package:flutter_client/src/application/features/settings/controller/client_update_controller.dart';
import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/client_update_gateway.dart';
import 'package:flutter_client/src/contracts/client_update_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'signed update slice enforces check-download-verify-plan order',
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
      await controller.verify();
      await controller.planApply();

      expect(gateway.calls, ['check', 'download', 'verify', 'apply']);
      expect(controller.manifestPath, 'manifest.json');
      expect(controller.publicKeysPath, 'keys.json');
      expect(controller.artifactReceiptId, startsWith('sha256:'));
      expect(controller.status.phase, ClientUpdatePhase.applyPlanned);
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
    expect(updates.last.errorCode, 'client_update_download_failed');
  });
}

final class _FakeClientUpdateGateway implements ClientUpdateGateway {
  final List<String> calls = [];
  bool failCheck = false;
  bool mismatchDownloadReceipt = false;

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
  );

  @override
  Future<ClientUpdateStatus> applyDryRun({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
    String stagingRoot = '',
  }) async {
    calls.add('apply');
    return _status(ClientUpdatePhase.applyPlanned);
  }

  @override
  Future<ClientUpdateStatus> check({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
  }) async {
    calls.add('check');
    if (failCheck) throw StateError('check_failed');
    return _status(ClientUpdatePhase.updateAvailable);
  }

  @override
  Future<ClientUpdateStatus> download({
    required AgentCommandRunner agentService,
    required String manifestPath,
    required String publicKeysPath,
    required String sourcePath,
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
