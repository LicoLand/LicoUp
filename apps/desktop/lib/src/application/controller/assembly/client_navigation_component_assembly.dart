import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;

import 'package:flutter_client/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

final class ClientNavigationComponentAssembly {
  ClientNavigationComponentAssembly({
    required bool Function() isMobileRuntime,
    required VoidCallback onEnterAgents,
    required VoidCallback onEnterMonitoring,
    required VoidCallback onExitMonitoring,
    required VoidCallback onEnterMobileRelay,
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
       );

  final ClientNavigationController controller;

  Iterable<ChangeNotifier> get listenables => [controller];

  void dispose() => controller.dispose();
}
