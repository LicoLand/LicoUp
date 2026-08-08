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

/// Native delivery channels an agent itself ships, as opposed to a
/// LicoUp-installed adapter plugin or LicoUp-owned gateway.
enum AdapterNativeCapabilityKind {
  desktop('desktop'),
  cli('cli'),
  acp('acp'),
  rpc('rpc'),
  appServer('app-server'),
  gateway('gateway'),
  localServer('local-server'),
  webServer('web-server'),
  tuiGateway('tui-gateway');

  const AdapterNativeCapabilityKind(this.wireName);

  final String wireName;

  static AdapterNativeCapabilityKind parse(Object? value) => switch (value) {
    'desktop' => desktop,
    'cli' => cli,
    'acp' => acp,
    'rpc' => rpc,
    'app-server' => appServer,
    'gateway' => gateway,
    'local-server' => localServer,
    'web-server' => webServer,
    'tui-gateway' => tuiGateway,
    _ => throw const FormatException('adapter_native_capability_kind_invalid'),
  };
}

final class AdapterNativeCapability {
  AdapterNativeCapability({
    required this.kind,
    required this.detected,
    required this.running,
    this.pid,
    this.processName,
    this.port,
  });

  factory AdapterNativeCapability.fromJson(Map<Object?, Object?> json) {
    final kind = AdapterNativeCapabilityKind.parse(json['kind']);
    final detected = json['detected'];
    if (detected is! bool) {
      throw const FormatException('adapter_plugin_catalog_invalid');
    }
    final running = switch (json['running']) {
      null => false,
      final bool value => value,
      _ => throw const FormatException('adapter_plugin_catalog_invalid'),
    };
    final pid = switch (json['pid']) {
      null => null,
      final int value => value,
      _ => throw const FormatException('adapter_plugin_catalog_invalid'),
    };
    final processName = switch (json['processName']) {
      null => null,
      final String value => value,
      _ => throw const FormatException('adapter_plugin_catalog_invalid'),
    };
    final port = switch (json['port']) {
      null => null,
      final int value => value,
      _ => throw const FormatException('adapter_plugin_catalog_invalid'),
    };
    return AdapterNativeCapability(
      kind: kind,
      detected: detected,
      running: running,
      pid: pid,
      processName: processName,
      port: port,
    );
  }

  final AdapterNativeCapabilityKind kind;
  final bool detected;

  /// Live on-host evidence: a process (and, for servers, a listening port)
  /// proving the capability is effective right now.
  final bool running;
  final int? pid;
  final String? processName;
  final int? port;
}

/// A LicoUp-managed adapter plugin entry (for example the Antigravity ACP
/// bridge or the Codex subagent relay). Only plugins with real install
/// management appear here.
final class AdapterPluginEntry {
  AdapterPluginEntry({
    required this.id,
    required this.label,
    required this.detail,
    required this.installationState,
    required Set<AdapterPluginLifecycleAction> lifecycleActions,
  }) : lifecycleActions = UnmodifiableSetView(Set.of(lifecycleActions));

  factory AdapterPluginEntry.fromJson(Map<Object?, Object?> json) {
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
    return AdapterPluginEntry(
      id: requiredString('id'),
      label: requiredString('label'),
      detail: json['detail'] is String ? json['detail'] as String : '',
      installationState: requiredString('installationState'),
      lifecycleActions: actions,
    );
  }

  final String id;
  final String label;
  final String detail;
  final String installationState;
  final Set<AdapterPluginLifecycleAction> lifecycleActions;

  bool supports(AdapterPluginLifecycleAction action) =>
      lifecycleActions.contains(action);
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
    required List<AdapterNativeCapability> nativeCapabilities,
    required List<AdapterPluginEntry> plugins,
  }) : lifecycleActions = UnmodifiableSetView(Set.of(lifecycleActions)),
       nativeCapabilities = UnmodifiableListView(nativeCapabilities),
       plugins = UnmodifiableListView(plugins);

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

    final nativeCapabilities = <AdapterNativeCapability>[];
    final capabilityKinds = <AdapterNativeCapabilityKind>{};
    final rawCapabilities = json['nativeCapabilities'];
    if (rawCapabilities != null) {
      if (rawCapabilities is! List) {
        throw const FormatException('adapter_plugin_catalog_invalid');
      }
      for (final raw in rawCapabilities) {
        if (raw is! Map) {
          throw const FormatException('adapter_plugin_catalog_invalid');
        }
        final capability = AdapterNativeCapability.fromJson(raw);
        if (!capabilityKinds.add(capability.kind)) {
          throw const FormatException('adapter_native_capability_duplicate');
        }
        nativeCapabilities.add(capability);
      }
    }

    final plugins = <AdapterPluginEntry>[];
    final pluginIds = <String>{};
    final rawPlugins = json['adapterPlugins'];
    if (rawPlugins != null) {
      if (rawPlugins is! List) {
        throw const FormatException('adapter_plugin_catalog_invalid');
      }
      for (final raw in rawPlugins) {
        if (raw is! Map) {
          throw const FormatException('adapter_plugin_catalog_invalid');
        }
        final plugin = AdapterPluginEntry.fromJson(raw);
        if (!pluginIds.add(plugin.id)) {
          throw const FormatException('adapter_plugin_entry_duplicate');
        }
        plugins.add(plugin);
      }
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
      nativeCapabilities: nativeCapabilities,
      plugins: plugins,
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
  final List<AdapterNativeCapability> nativeCapabilities;
  final List<AdapterPluginEntry> plugins;

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
