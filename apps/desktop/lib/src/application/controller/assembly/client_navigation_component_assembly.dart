import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;

import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_section_preload_controller.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

export 'package:licoup/src/application/features/navigation/controller/client_section_preload_controller.dart';

typedef ClientSectionPreloadTaskMap =
    Map<ClientSection, Future<void> Function()>;

final class ClientNavigationComponentAssembly {
  ClientNavigationComponentAssembly({
    required bool Function() isMobileRuntime,
    required VoidCallback onEnterAgents,
    required VoidCallback onEnterMonitoring,
    required VoidCallback onExitMonitoring,
    required VoidCallback onEnterMobileRelay,
    required ClientSectionPreloadTaskMap sectionPreloadTasks,
    required ClientLifecycleReportSink onPreloadReport,
  }) : controller = ClientNavigationController(
         isMobileRuntime: isMobileRuntime,
         hooks: {
           ClientSection.agents: ClientSectionHooks(
             onEnter: onEnterAgents,
             onReselect: onEnterAgents,
           ),
           ClientSection.monitoring: ClientSectionHooks(
             onEnter: onEnterMonitoring,
             onExit: onExitMonitoring,
           ),
           ClientSection.mobileRelay: ClientSectionHooks(
             onEnter: onEnterMobileRelay,
           ),
         },
       ) {
    preloadController = ClientSectionPreloadController(
      currentSection: () => controller.currentSection,
      tasks: sectionPreloadTasks,
      onReport: onPreloadReport,
    );
  }

  final ClientNavigationController controller;
  late final ClientSectionPreloadController preloadController;

  Iterable<ChangeNotifier> get listenables => [controller];

  void dispose() {
    preloadController.dispose();
    controller.dispose();
  }
}
