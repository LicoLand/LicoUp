/// Build-time inclusion flag for the multi-agent routing module.
///
/// Packaging sets this to `false` when the module is excluded from a build.
/// Runtime toggle is separate and only applies when this flag is `true`.
const bool kRoutingModuleIncluded = bool.fromEnvironment(
  'LICO_ROUTING_MODULE_INCLUDED',
  defaultValue: true,
);

/// Settings keys owned by the routing module (must be cleared on unload).
const List<String> routingModuleSettingsKeys = [
  'routing.enabled',
  'routing.policyPath',
];

/// State directory relative to the portable data root.
const String routingModuleStateDirectory = 'lico-client/routing';
