import 'dart:io';

import 'package:flutter_client/src/application/features/routing/excluded_routing_module_registration.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_registration_impl.dart';
import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';

/// Creates the routing boundary selected at compilation time.
///
/// `kRoutingModuleIncluded` is a compile-time environment constant. In an AOT
/// excluded build the concrete registration branch and its routing graph are
/// unreachable and can be removed by tree shaking.
RoutingModuleRegistration createRoutingModuleRegistration({
  required Directory rootDirectory,
  Map<String, String>? settings,
  bool initiallyEnabled = true,
}) {
  if (!kRoutingModuleIncluded) {
    return const ExcludedRoutingModuleRegistration();
  }
  return DefaultRoutingModuleRegistration(
    rootDirectory: rootDirectory,
    settings: settings,
    initiallyEnabled: initiallyEnabled,
  );
}
