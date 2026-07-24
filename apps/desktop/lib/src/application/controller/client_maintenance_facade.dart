import 'package:licoup/src/application/features/settings/controller/client_log_export_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_update_controller.dart';
import 'package:licoup/src/application/features/settings/controller/directory_path_controller.dart';
import 'package:licoup/src/contracts/client_update_models.dart';

mixin ClientMaintenanceFacade {
  ClientLogExportController get clientLogExportController;
  ClientUpdateController get clientUpdateController;
  DirectoryPathController get directoryPathController;

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

  Future<void> downloadClientUpdateArtifact({required String sourcePath}) =>
      clientUpdateController.download(sourcePath: sourcePath);

  Future<void> verifyClientUpdateArtifact() => clientUpdateController.verify();

  Future<void> planClientUpdateApply() => clientUpdateController.planApply();

  Future<void> openDirectoryPath(String path, {String caption = ''}) =>
      directoryPathController.open(path, caption: caption);
}
