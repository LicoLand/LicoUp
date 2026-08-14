import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;

import 'package:licoup/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:licoup/src/application/features/settings/controller/client_log_export_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_update_controller.dart';
import 'package:licoup/src/application/features/settings/controller/directory_path_controller.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:licoup/src/backend/features/settings/services/client_update_service.dart';
import 'package:licoup/src/backend/features/settings/services/optional_collaboration_service.dart';
import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/runtime_platform_bridge.dart';
import 'package:licoup/src/platform/storage/client_log_export_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

final class ClientSettingsComponentAssembly {
  ClientSettingsComponentAssembly({
    required PortableDataRoot portableData,
    required AgentService agentService,
    required ClientUpdateService clientUpdateService,
    required ClientLogExportService clientLogExportService,
    required RuntimePlatformBridge runtimePlatformBridge,
    required String Function() directoryCaption,
    required ClientComponentStatusSink reportStatus,
    required VoidCallback notifyStateChanged,
    OptionalCollaborationGateway? optionalCollaborationGateway,
    Future<void> Function()? onCatalogPurge,
  }) : logExportController = ClientLogExportController(
         exporter: clientLogExportService,
         portableData: portableData,
         onStatus: (update) => reportStatus(
           chinese: update.chinese,
           english: update.english,
           caption: update.caption,
           errorCode: update.error?.toString() ?? '',
         ),
       ),
       updateController = ClientUpdateController(
         gateway: clientUpdateService,
         agentService: agentService,
         dataDirectory: () async => (await portableData.dataDirectory()).path,
         onStatus: (update) => reportStatus(
           chinese: update.chinese,
           english: update.english,
           caption: 'Update',
           errorCode: update.errorCode,
         ),
       ),
       optionalCollaborationController = OptionalCollaborationController(
         gateway:
             optionalCollaborationGateway ??
             OptionalCollaborationService(runner: agentService),
         onStatus: (update) => reportStatus(
           chinese: update.chinese,
           english: update.english,
           caption: 'Optional collaboration',
           errorCode: update.errorCode,
         ),
         onCatalogPurge: onCatalogPurge,
       ),
       directoryPathController = DirectoryPathController(
         opener: runtimePlatformBridge,
         defaultCaption: directoryCaption,
         onStatus: (update) {
           reportStatus(
             chinese: update.chinese,
             english: update.english,
             caption: update.caption,
             errorCode: update.error?.toString() ?? '',
           );
           notifyStateChanged();
         },
       );

  final ClientLogExportController logExportController;
  final ClientUpdateController updateController;
  final OptionalCollaborationController optionalCollaborationController;
  final DirectoryPathController directoryPathController;

  Iterable<ChangeNotifier> get listenables => [
    logExportController,
    updateController,
    optionalCollaborationController,
  ];

  void dispose() {
    optionalCollaborationController.dispose();
    updateController.dispose();
    logExportController.dispose();
  }
}
