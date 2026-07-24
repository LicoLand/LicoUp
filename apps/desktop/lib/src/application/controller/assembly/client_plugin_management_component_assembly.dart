import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'package:licoup/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:licoup/src/application/features/plugin_management/controller/adapter_plugin_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

final class ClientPluginManagementComponentAssembly {
  ClientPluginManagementComponentAssembly({
    required AgentCommandRunner runner,
    required ClientComponentStatusSink reportStatus,
  }) : adapterPluginController = AdapterPluginController(
         runner: runner,
         onStatus: (update) => reportStatus(
           chinese: update.chinese,
           english: update.english,
           caption: 'Plugins',
           errorCode: update.errorCode,
         ),
       );

  final AdapterPluginController adapterPluginController;

  Iterable<ChangeNotifier> get listenables => [adapterPluginController];

  void dispose() => adapterPluginController.dispose();
}
