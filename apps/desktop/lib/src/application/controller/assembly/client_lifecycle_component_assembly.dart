import 'package:licoup/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';

final class ClientLifecycleComponentAssembly {
  ClientLifecycleComponentAssembly({
    required ClientComponentStatusSink reportStatus,
  }) : controller = ClientLifecycleCoordinator(
         onReport: (report) {
           if (report.code == 'client_lifecycle_disposed' ||
               report.code == 'client_lifecycle_transition_invalid') {
             return;
           }
           reportStatus(
             chinese: '初始化失败。',
             english: 'Initialization failed.',
             caption: 'Error',
             errorCode: report.code,
           );
         },
       );

  final ClientLifecycleCoordinator controller;

  void dispose() => controller.dispose();
}
