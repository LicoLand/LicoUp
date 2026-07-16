import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'package:flutter_client/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:flutter_client/src/application/features/catalog_convergence/services/catalog_convergence_service.dart';
import 'package:flutter_client/src/contracts/catalog_convergence/catalog_convergence_gateway.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';

final class ClientCatalogConvergenceComponentAssembly {
  ClientCatalogConvergenceComponentAssembly({
    required AgentService agentService,
    CatalogConvergenceGateway? gateway,
  }) : controller = CatalogConvergenceController(
         gateway:
             gateway ?? CatalogConvergenceService(agentService: agentService),
       );

  final CatalogConvergenceController controller;

  Iterable<ChangeNotifier> get listenables => [controller];

  void dispose() => controller.dispose();
}
