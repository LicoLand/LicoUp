import 'package:licoup/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:licoup/src/application/features/plugin_management/controller/adapter_plugin_controller.dart';
import 'package:licoup/src/application/features/plugin_management/controller/package_center_controller.dart';
import 'package:licoup/src/application/features/plugin_management/controller/package_recommendation_controller.dart';
import 'package:licoup/src/application/features/plugin_management/models/package_first_launch_record.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

final class ClientPluginManagementComponentAssembly {
  ClientPluginManagementComponentAssembly({
    required AgentCommandRunner runner,
    required PortableDataRoot portableData,
    required ClientComponentStatusSink reportStatus,
  }) : adapterPluginController = AdapterPluginController(
         runner: runner,
         onStatus: (update) => reportStatus(
           chinese: update.chinese,
           english: update.english,
           caption: 'Plugins',
           errorCode: update.errorCode,
         ),
       ),
       packageCenterController = PackageCenterController(
         runner: runner,
         onStatus: (update) => reportStatus(
           chinese: update.chinese,
           english: update.english,
           caption: 'Packages',
           errorCode: update.errorCode,
         ),
       ) {
    packageRecommendationController = PackageRecommendationController(
      installer: _NarrowedPackageInstallSource(packageCenterController),
      store: FilePackageFirstLaunchStore(portableData),
    );
  }

  final AdapterPluginController adapterPluginController;
  final PackageCenterController packageCenterController;
  late final PackageRecommendationController packageRecommendationController;

  void dispose() {
    packageRecommendationController.dispose();
    packageCenterController.dispose();
    adapterPluginController.dispose();
  }
}

/// Routes a recommendation install to the native package transaction.
///
/// It holds only the archive path the offer carried. It cannot reach the legacy
/// adapter family, so an offered capability is never installed through the
/// third-party Agent path, and it never decides whether a package is installed.
final class _NarrowedPackageInstallSource
    implements PackageRecommendationInstallPort {
  _NarrowedPackageInstallSource(this._packages);

  final PackageCenterController _packages;

  @override
  Future<bool> installFromArchive(String archive) =>
      _packages.installFromArchive(archive);
}
