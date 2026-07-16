import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'package:flutter_client/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:flutter_client/src/application/controller/client_lifecycle_coordinator.dart';

final class ClientLifecycleComponentAssembly {
  ClientLifecycleComponentAssembly({
    required void Function(bool initialized) onInitializedChanged,
    required ClientComponentStatusSink reportStatus,
  }) : controller = ClientLifecycleCoordinator(
         onReport: (report) {
           onInitializedChanged(false);
           reportStatus(
             chinese: '初始化失败。',
             english: 'Initialization failed.',
             caption: 'Error',
             errorCode: report.code,
           );
         },
       );

  final ClientLifecycleCoordinator controller;

  Iterable<ChangeNotifier> get listenables => [controller];

  void dispose() => controller.dispose();
}
