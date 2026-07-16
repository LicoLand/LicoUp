import 'dart:io';

import 'package:flutter_client/src/application/controller/client_component_assembly.dart';
import 'package:flutter_client/src/application/controller/client_conversation_facade.dart';
import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/application/features/routing/controller/routing_policy_editor_adapter.dart';
import 'package:flutter_client/src/application/features/routing/controller/routing_module_lifecycle_controller.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';
import 'package:flutter_client/src/contracts/routing/task_route_coordinator_port.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';

mixin ClientRoutingFacade
    on AgentWorkspaceCoordinator, ClientConversationFacade {
  ClientComponentAssembly get componentAssembly;
  RoutingModuleLifecycleController get routingLifecycleController;
  PortableDataRoot get portableData;

  Directory? get clientRoutingRootDirectory =>
      componentAssembly.routingRootDirectory;
  set clientRoutingRootDirectory(Directory? value) {
    componentAssembly.routingRootDirectory = value;
  }

  Future<RoutingModuleRegistration> ensureRoutingModuleReady({
    Directory? rootDirectory,
  }) async {
    clientRoutingRootDirectory =
        rootDirectory ??
        clientRoutingRootDirectory ??
        await portableData.dataDirectory();
    return routingLifecycleController.ensureReady();
  }

  Future<void> bindRoutingModulePolicyEvents(
    RoutingModuleRegistration registration,
  ) => routingLifecycleController.bind(registration);

  void clientApplyRoutingPolicy(
    RoutingPolicyDocument document,
    TaskRouteCoordinatorPort? coordinator,
  ) {
    agentOrchestrationPolicy = orchestrationEditorFromRoutingPolicy(document);
    syncAgentOrchestrationPolicy();
    notifyClientStateChanged();
    final taskId = activeOrchestrationTaskId;
    if (taskId.isNotEmpty && coordinator?.sessionFor(taskId) != null) {
      coordinator!.queuePolicy(document);
    }
  }

  @override
  RoutingModuleRegistration? get agentWorkspaceRoutingModule =>
      routingLifecycleController.registration;

  @override
  set agentWorkspaceRoutingModule(RoutingModuleRegistration? value) {
    routingLifecycleController.replaceRegistration(value);
  }

  @override
  Future<RoutingModuleRegistration> agentWorkspaceEnsureRoutingModuleReady() =>
      ensureRoutingModuleReady();

  @override
  Future<void> agentWorkspaceBindRoutingModulePolicyEvents(
    RoutingModuleRegistration registration,
  ) => bindRoutingModulePolicyEvents(registration);

  @override
  Future<void> agentWorkspaceUnbindRoutingModulePolicyEvents() =>
      routingLifecycleController.unbind();
}
