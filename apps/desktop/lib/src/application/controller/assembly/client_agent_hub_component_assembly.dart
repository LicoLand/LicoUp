import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
import 'package:licoup/src/application/features/agent_hub/agent_hub_engine.dart';
import 'package:licoup/src/contracts/agent_hub.dart';

/// Owns the native Agent Hub engine and its application catalog projection.
/// Feature panels receive the controller and never create their own engine.
final class ClientAgentHubComponentAssembly {
  ClientAgentHubComponentAssembly({required AgentHubNativeInvoke invoke}) {
    engine = NativeAgentHubEngine(invoke: invoke);
    controller = AgentHubCatalogController(engine: engine);
  }

  late final AgentHubEnginePort engine;
  late final AgentHubCatalogController controller;

  Iterable<ChangeNotifier> get listenables => [controller];

  void dispose() => controller.dispose();
}
