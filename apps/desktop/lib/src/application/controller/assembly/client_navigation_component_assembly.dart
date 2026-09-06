import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/features/navigation/controller/client_interface_entry_hook_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

export 'package:licoup/src/application/features/navigation/controller/client_interface_entry_hook_controller.dart';

typedef ClientInterfaceEntryHookTaskMap =
    Map<ClientSection, ClientInterfaceEntryHookTask>;

final class ClientNavigationComponentAssembly {
  ClientNavigationComponentAssembly({
    required bool Function() isMobileRuntime,
    required ApplicationCallback onEnterMonitoring,
    required ApplicationCallback onExitMonitoring,
    required ClientInterfaceEntryHookTaskMap entryHookTasks,
    required ClientLifecycleReportSink onEntryHookReport,
  }) : controller = ClientNavigationController(
         isMobileRuntime: isMobileRuntime,
         hooks: {
           ClientSection.monitoring: ClientSectionHooks(
             onEnter: onEnterMonitoring,
             onExit: onExitMonitoring,
           ),
         },
       ) {
    entryHookController = ClientInterfaceEntryHookController(
      tasks: entryHookTasks,
      onReport: onEntryHookReport,
    );
  }

  final ClientNavigationController controller;
  late final ClientInterfaceEntryHookController entryHookController;

  void dispose() {
    entryHookController.dispose();
    controller.dispose();
  }
}
