import 'package:flutter/foundation.dart' show debugPrint;

import 'package:licoup/src/application/features/settings/controller/client_log_export_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_update_controller.dart';
import 'package:licoup/src/application/features/settings/controller/directory_path_controller.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

mixin ClientMaintenanceFacade {
  AgentService get agentService;
  ClientLogExportController get clientLogExportController;
  ClientUpdateController get clientUpdateController;
  DirectoryPathController get directoryPathController;
  Map<String, dynamic>? opencodeServeState;

  String get clientLogExportPath => clientLogExportController.exportedPath;

  bool get isExportingClientLogs => clientLogExportController.busy;

  Future<void> exportClientLogs(String destinationPath) =>
      clientLogExportController.export(destinationPath);

  ClientUpdateStatus get clientUpdateStatus => clientUpdateController.status;

  String get clientUpdateManifestPath => clientUpdateController.manifestPath;

  String get clientUpdatePublicKeysPath =>
      clientUpdateController.publicKeysPath;

  String get clientUpdateArtifactReceiptId =>
      clientUpdateController.artifactReceiptId;

  String get clientUpdateSource => clientUpdateController.source;

  String get clientUpdateRepo => clientUpdateController.repo;

  bool get isClientUpdateBusy => clientUpdateController.busy;

  Future<void> refreshClientUpdateStatus({String channel = 'stable'}) =>
      clientUpdateController.refresh(channel: channel);

  Future<void> checkClientUpdate({
    required String manifestPath,
    required String publicKeysPath,
    String channel = 'stable',
    String revocationPath = '',
  }) => clientUpdateController.check(
    manifestPath: manifestPath,
    publicKeysPath: publicKeysPath,
    channel: channel,
    revocationPath: revocationPath,
  );

  Future<void> checkClientUpdateFromGithub({String repo = 'LicoLand/LicoUp'}) =>
      clientUpdateController.checkGithub(repo: repo);

  Future<void> downloadClientUpdateArtifact({required String sourcePath}) =>
      clientUpdateController.download(sourcePath: sourcePath);

  Future<void> downloadClientUpdateFromGithub() =>
      clientUpdateController.downloadGithub();

  Future<void> verifyClientUpdateArtifact() => clientUpdateController.verify();

  Future<void> planClientUpdateApply() => clientUpdateController.planApply();

  Future<void> applyClientUpdateThenExit(void Function() exitClient) =>
      clientUpdateController.applyThenExit(exitClient);

  Future<void> rollbackClientUpdate() => clientUpdateController.rollback();

  Future<void> openDirectoryPath(String path, {String caption = ''}) =>
      directoryPathController.open(path, caption: caption);

  Future<void> ensureOpencodeServeSilently() async {
    try {
      opencodeServeState = await agentService.ensureOpencodeServe();
      if (opencodeServeState?['ok'] != true) {
        debugPrint('OpenCode serve bootstrap unavailable.');
      }
    } catch (_) {
      opencodeServeState = <String, dynamic>{
        'ok': false,
        'status': 'unavailable',
        'errorCode': 'opencode_serve_unavailable',
      };
      debugPrint('OpenCode serve bootstrap failed.');
    }
  }

  /// Coordinator-facing runtime authorization entry; satisfies
  /// [AgentWorkspaceCoordinator] once mixed into the root controller.
  Future<Map<String, dynamic>> agentWorkspaceAuthorizeRuntime(
    String agentId, {
    String binaryPath = '',
  }) {
    if (agentId.trim() != 'antigravity') {
      return Future.value(const <String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{'code': 'runtime_authorize_unsupported'},
      });
    }
    return agentService.authorizeAntigravityRuntime(binaryPath: binaryPath);
  }
}
