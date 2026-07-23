import 'dart:collection';

const adapterPluginCatalogSchema = 'lico.adapter-plugin-catalog.v1';

enum AdapterPluginManagementKind {
  native('native'),
  bundledAcp('bundled-acp'),
  managedBridge('managed-bridge');

  const AdapterPluginManagementKind(this.wireName);

  final String wireName;

  static AdapterPluginManagementKind parse(Object? value) => switch (value) {
    'native' => native,
    'bundled-acp' => bundledAcp,
    'managed-bridge' => managedBridge,
    _ => throw const FormatException('adapter_plugin_management_kind_invalid'),
  };
}

enum AdapterPluginLifecycleAction {
  install,
  uninstall;

  static AdapterPluginLifecycleAction parse(Object? value) => switch (value) {
    'install' => install,
    'uninstall' => uninstall,
    _ => throw const FormatException('adapter_plugin_lifecycle_action_invalid'),
  };
}

final class AdapterPluginDescriptor {
  AdapterPluginDescriptor({
    required this.agentId,
    required this.label,
    required this.driverId,
    required this.runtimeProtocol,
    required this.laneFamily,
    required this.managementKind,
    required this.installationState,
    required this.readiness,
    required Set<AdapterPluginLifecycleAction> lifecycleActions,
  }) : lifecycleActions = UnmodifiableSetView(Set.of(lifecycleActions));

  factory AdapterPluginDescriptor.fromJson(Map<Object?, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('adapter_plugin_catalog_invalid');
      }
      return value;
    }

    final rawActions = json['lifecycleActions'];
    if (rawActions is! List) {
      throw const FormatException('adapter_plugin_catalog_invalid');
    }
    final actions = <AdapterPluginLifecycleAction>{};
    for (final value in rawActions) {
      if (!actions.add(AdapterPluginLifecycleAction.parse(value))) {
        throw const FormatException(
          'adapter_plugin_lifecycle_action_duplicate',
        );
      }
    }
    final managementKind = AdapterPluginManagementKind.parse(
      json['managementKind'],
    );
    if (actions.isNotEmpty &&
        managementKind != AdapterPluginManagementKind.managedBridge) {
      throw const FormatException('adapter_plugin_builtin_action_invalid');
    }
    return AdapterPluginDescriptor(
      agentId: requiredString('agentId'),
      label: requiredString('label'),
      driverId: requiredString('driverId'),
      runtimeProtocol: requiredString('runtimeProtocol'),
      laneFamily: requiredString('laneFamily'),
      managementKind: managementKind,
      installationState: requiredString('installationState'),
      readiness: requiredString('readiness'),
      lifecycleActions: actions,
    );
  }

  final String agentId;
  final String label;
  final String driverId;
  final String runtimeProtocol;
  final String laneFamily;
  final AdapterPluginManagementKind managementKind;
  final String installationState;
  final String readiness;
  final Set<AdapterPluginLifecycleAction> lifecycleActions;

  bool supports(AdapterPluginLifecycleAction action) =>
      lifecycleActions.contains(action);
}

final class AdapterPluginCatalog {
  AdapterPluginCatalog({required List<AdapterPluginDescriptor> adapters})
    : adapters = UnmodifiableListView(adapters);

  factory AdapterPluginCatalog.fromJson(Map<String, dynamic> json) {
    if (json['ok'] != true ||
        json['schemaVersion'] != adapterPluginCatalogSchema) {
      throw const FormatException('adapter_plugin_catalog_invalid');
    }
    final rawAdapters = json['adapters'];
    if (rawAdapters is! List) {
      throw const FormatException('adapter_plugin_catalog_invalid');
    }
    final ids = <String>{};
    final adapters = <AdapterPluginDescriptor>[];
    for (final raw in rawAdapters) {
      if (raw is! Map) {
        throw const FormatException('adapter_plugin_catalog_invalid');
      }
      final adapter = AdapterPluginDescriptor.fromJson(raw);
      if (!ids.add(adapter.agentId)) {
        throw const FormatException('adapter_plugin_agent_duplicate');
      }
      adapters.add(adapter);
    }
    adapters.sort((left, right) {
      final kind = left.managementKind.index.compareTo(
        right.managementKind.index,
      );
      return kind != 0 ? kind : left.label.compareTo(right.label);
    });
    return AdapterPluginCatalog(adapters: adapters);
  }

  final List<AdapterPluginDescriptor> adapters;

  AdapterPluginDescriptor? adapter(String agentId) {
    for (final adapter in adapters) {
      if (adapter.agentId == agentId) return adapter;
    }
    return null;
  }
}
