import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'package:flutter_client/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:flutter_client/src/application/features/routing/controller/routing_module_lifecycle_controller.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_registration_factory.dart';

final class ClientRoutingComponentAssembly {
  ClientRoutingComponentAssembly({
    required Directory? Function() rootDirectory,
    required ClientRoutingPolicySink onRoutingPolicy,
    required ClientComponentStatusSink reportStatus,
  }) : controller = RoutingModuleLifecycleController(
         createRegistration: () {
           final root = rootDirectory();
           if (root == null) throw StateError('routing_root_unavailable');
           return createRoutingModuleRegistration(rootDirectory: root);
         },
         onPolicyLoaded: onRoutingPolicy,
         onError: (errorCode) => reportStatus(
           chinese: '',
           english: '',
           caption: 'Agent orchestration',
           errorCode: errorCode,
         ),
       );

  final RoutingModuleLifecycleController controller;

  Iterable<ChangeNotifier> get listenables => [controller];

  void dispose() => controller.dispose();
}
