class TargetCandidate {
  final String id;
  final String target;
  final String label;
  final String kind;
  final String status;
  final bool configured;
  final double confidence;
  final String? detail;
  final String? configPath;
  final String? binaryPath;
  final List<String> historyRoots;
  final bool manual;
  final String adapterStatus;
  final Map<String, dynamic> adapterCapabilities;
  final List<String> supportedActions;
  final String scanSource;
  final String location;
  final Map<String, dynamic> runtimeConnection;
  final Map<String, dynamic> modelCatalog;

  TargetCandidate({
    String? id,
    required this.target,
    required this.label,
    required this.kind,
    required this.status,
    required this.configured,
    required this.confidence,
    this.detail,
    this.configPath,
    this.binaryPath,
    List<String>? historyRoots,
    this.manual = false,
    required this.adapterStatus,
    Map<String, dynamic>? adapterCapabilities,
    List<String>? supportedActions,
    this.scanSource = '',
    this.location = 'local',
    Map<String, dynamic>? runtimeConnection,
    Map<String, dynamic>? modelCatalog,
  }) : id = id ?? target,
       historyRoots = historyRoots ?? const [],
       adapterCapabilities = adapterCapabilities ?? const {},
       supportedActions = supportedActions ?? const [],
       runtimeConnection = Map.unmodifiable(runtimeConnection ?? const {}),
       modelCatalog = modelCatalog ?? const {};

  bool supportsAction(String action) {
    return supportedActions.contains(action);
  }

  bool get visibleInClient => status != 'not-detected';
  bool get isConversationAgent =>
      visibleInClient &&
      target != 'code' &&
      (location == 'local' || hasValidVirtualMachineConnection);
  bool get isVirtualMachine => location == 'virtual-machine';
  bool get hasValidVirtualMachineConnection {
    if (!isVirtualMachine || !const {'openclaw', 'hermes'}.contains(target)) {
      return false;
    }
    const allowedKeys = {
      'kind',
      'host',
      'port',
      'user',
      'remoteExecutable',
      'workingDirectory',
      'runtimeProtocol',
    };
    if (runtimeConnection.keys.any((key) => !allowedKeys.contains(key))) {
      return false;
    }
    final hostValue = runtimeConnection['host'];
    final userValue = runtimeConnection['user'];
    final executableValue = runtimeConnection['remoteExecutable'];
    final workingDirectoryValue = runtimeConnection['workingDirectory'];
    final runtimeProtocolValue = runtimeConnection['runtimeProtocol'];
    if (hostValue is! String ||
        executableValue is! String ||
        workingDirectoryValue is! String ||
        (userValue != null && userValue is! String) ||
        (runtimeProtocolValue != null && runtimeProtocolValue is! String)) {
      return false;
    }
    final host = hostValue;
    final executable = executableValue;
    final workingDirectory = workingDirectoryValue;
    final port = runtimeConnection['port'];
    return runtimeConnection['kind'] == 'ssh' &&
        host.trim() == host &&
        host.isNotEmpty &&
        host.length <= 255 &&
        !host.startsWith('-') &&
        RegExp(r'^[A-Za-z0-9._:\[\]-]+$').hasMatch(host) &&
        (userValue == null ||
            (userValue.isNotEmpty &&
                userValue.length <= 255 &&
                !userValue.startsWith('-') &&
                RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(userValue))) &&
        executable.trim() == executable &&
        executable.isNotEmpty &&
        executable.length <= 1024 &&
        !executable.startsWith('-') &&
        !executable.contains(RegExp(r'[\r\n\u0000]')) &&
        workingDirectory.trim() == workingDirectory &&
        workingDirectory.length <= 4096 &&
        workingDirectory.startsWith('/') &&
        !workingDirectory.contains(RegExp(r'[\r\n\u0000]')) &&
        (runtimeProtocolValue == null ||
            (target == 'hermes' &&
                runtimeProtocolValue == 'hermes-tui-gateway')) &&
        (port == null || (port is int && port > 0 && port <= 65535));
  }

  String get remoteWorkingDirectory => hasValidVirtualMachineConnection
      ? runtimeConnection['workingDirectory'].toString()
      : '';

  String get virtualMachineDestination {
    if (!hasValidVirtualMachineConnection) {
      return '';
    }
    final rawHost = runtimeConnection['host'].toString();
    final host = rawHost.contains(':') && !rawHost.startsWith('[')
        ? '[$rawHost]'
        : rawHost;
    final user = runtimeConnection['user']?.toString() ?? '';
    final port = runtimeConnection['port'];
    final identity = user.isEmpty ? host : '$user@$host';
    return port is int ? '$identity:$port' : identity;
  }

  String get conversationDriverStatus =>
      (adapterCapabilities['conversationDriver'] ?? 'unsupported').toString();
  String get conversationProtocol =>
      (adapterCapabilities['conversationProtocol'] ?? '').toString();
  String get conversationReadiness =>
      (adapterCapabilities['conversationReadiness'] ?? 'unverified').toString();
  String get conversationBlocker =>
      (adapterCapabilities['conversationBlocker'] ?? '').toString();
  Map<String, dynamic> get conversationProbe =>
      adapterCapabilities['conversationProbe'] is Map
      ? Map<String, dynamic>.from(
          adapterCapabilities['conversationProbe'] as Map,
        )
      : const {};
  Map<String, dynamic> get conversationCapabilityMatrix =>
      adapterCapabilities['conversationCapabilityMatrix'] is Map
      ? Map<String, dynamic>.from(
          adapterCapabilities['conversationCapabilityMatrix'] as Map,
        )
      : const {};
  List<String> get conversationSummaryCodes {
    final raw = adapterCapabilities['conversationSummaryCodes'];
    if (raw is! List) {
      final blocker = conversationBlocker.trim();
      return blocker.isEmpty ? const [] : [blocker];
    }
    return raw
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  int get conversationConsecutivePasses {
    final raw = adapterCapabilities['conversationConsecutivePasses'];
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  String get conversationEvidenceAge =>
      (adapterCapabilities['conversationEvidenceAge'] ?? '').toString();

  String get conversationSendGateReason {
    if (isVirtualMachine && !hasValidVirtualMachineConnection) {
      return 'virtual_machine_connection_invalid';
    }
    if ((binaryPath ?? '').trim().isEmpty) {
      return 'native_agent_executable_not_detected';
    }
    if (conversationDriverStatus == 'unsupported') {
      return 'native_agent_runtime_profile_unavailable';
    }
    return 'runtime_message_send_unavailable';
  }

  /// Supported conversation targets are client-accessible by default: parity
  /// evidence (conversationReadiness) stays informational and never gates
  /// runtime use. Only runtimes without a driver profile, an executable
  /// binding, or a valid explicit VM connection are excluded. The projected
  /// supported-action list is informational and cannot veto a resolvable path.
  bool get canRelayRuntime =>
      visibleInClient &&
      (location == 'local' || hasValidVirtualMachineConnection) &&
      (binaryPath ?? '').trim().isNotEmpty &&
      conversationDriverStatus != 'unsupported';

  bool get supportsNativeInterruptSteer =>
      conversationCapabilityMatrix['interruptSteer'] == true;

  bool get canInstallSkill => supportsAction('skill.install');

  /// ACP lane support from adapter conversation metadata (not invented).
  bool get supportsAcpPlugin {
    final laneFamily = conversationCapabilityMatrix['laneFamily']
        ?.toString()
        .trim()
        .toLowerCase();
    if (laneFamily == 'acp') {
      return true;
    }
    final protocol = conversationProtocol.trim().toLowerCase();
    return protocol.contains('acp');
  }

  factory TargetCandidate.fromJson(Map<String, dynamic> json) {
    return TargetCandidate(
      id: json['id']?.toString(),
      target: (json['target'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      kind: (json['kind'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      configured: json['configured'] == true,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      detail: json['detail']?.toString(),
      configPath: json['configPath']?.toString(),
      binaryPath: json['binaryPath']?.toString(),
      historyRoots: json['historyRoots'] is List
          ? (json['historyRoots'] as List)
                .map((value) => value.toString())
                .toList()
          : null,
      manual: json['manual'] == true,
      adapterStatus: (json['adapterStatus'] ?? '').toString(),
      adapterCapabilities: json['adapterCapabilities'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['adapterCapabilities'] as Map)
          : null,
      supportedActions: json['supportedActions'] is List
          ? (json['supportedActions'] as List).whereType<String>().toList()
          : null,
      scanSource: (json['scanSource'] ?? '').toString(),
      location: (json['location'] ?? 'local').toString(),
      runtimeConnection: json['runtimeConnection'] is Map
          ? Map<String, dynamic>.from(json['runtimeConnection'] as Map)
          : null,
      modelCatalog: json['modelCatalog'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['modelCatalog'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'target': target,
      'label': label,
      'kind': kind,
      'status': status,
      'configured': configured,
      'confidence': confidence,
      if (detail != null) 'detail': detail,
      if (configPath != null) 'configPath': configPath,
      if (binaryPath != null) 'binaryPath': binaryPath,
      if (historyRoots.isNotEmpty) 'historyRoots': historyRoots,
      'manual': manual,
      'adapterStatus': adapterStatus,
      'adapterCapabilities': adapterCapabilities,
      'supportedActions': supportedActions,
      if (scanSource.isNotEmpty) 'scanSource': scanSource,
      'location': location,
      if (runtimeConnection.isNotEmpty) 'runtimeConnection': runtimeConnection,
      if (modelCatalog.isNotEmpty) 'modelCatalog': modelCatalog,
    };
  }
}
