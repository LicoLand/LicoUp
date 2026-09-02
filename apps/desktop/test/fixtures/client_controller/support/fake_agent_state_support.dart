import 'client_controller_scenario_dependencies.dart';
import 'client_controller_scenario_json.dart';

mixin FakeAgentStateSupport on AgentService {
  int scanTargetsCalls = 0;
  int scanOneTargetCalls = 0;
  final List<String> scannedOneTargetIds = <String>[];
  final List<bool> catalogLookups = <bool>[];
  int inspectTargetCalls = 0;
  int addTargetCalls = 0;
  int restoreSnapshotCount = 0;
  int listSnapshotsCalls = 0;
  int listPairingsCalls = 0;
  int requestPairingCalls = 0;
  int approvePairingCalls = 0;
  int revokePairingCalls = 0;
  int listSkillsCalls = 0;
  int requestSkillHubCalls = 0;
  int refreshSkillHubCalls = 0;

  int ensureOpencodeServeCalls = 0;
  int stopOpencodeServeCalls = 0;

  bool throwScanTargets = false;
  bool throwInspectTarget = false;
  bool throwAddTarget = false;
  bool throwRestoreSnapshot = false;
  bool throwListPairings = false;
  bool throwListSkills = false;

  String restoredSnapshotId = '';
  String addedTarget = '';
  String addedConfigPath = '';
  String addedHistoryRoot = '';

  String pairedAgent = '';
  List<TargetCandidate> scanTargetsResult = [
    TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: 'detected',
      configured: false,
      confidence: 0.82,
      detail: 'cli',
      manual: false,
      configPath: 'test-data/codex.toml',
      binaryPath: ['', 'opt', 'lico-test', 'bin', 'codex'].join('/'),
      adapterStatus: 'implemented',
      adapterCapabilities: parityReadyAdapterCapabilities,
      supportedActions: ['runtime.message.send'],
    ),
  ];
  Map<String, dynamic> pairingResult = {'ok': true, 'status': 'requested'};
  String pairingStatus = 'requested';
  List<Map<String, dynamic>> snapshots = [
    {'snapshotId': 'snapshot-codex-1', 'target': 'codex'},
  ];
  List<Map<String, dynamic>> pairings = [
    {'agentId': 'codex', 'target': 'manual', 'status': 'requested'},
  ];
  List<Map<String, dynamic>> skills = [
    {'skillId': 'review', 'version': '1.0.0'},
  ];
  Map<String, dynamic> opencodeServeStatusResult = {
    'ok': true,
    'status': 'running',
    'running': true,
    'healthy': true,
    'attachUrl': 'http://127.0.0.1:24173',
    'port': 24173,
  };

  Completer<void>? skillBusyGate;

  List<List<String>> cliCalls = const [];

  @override
  Future<List<TargetCandidate>> scanTargets() async {
    scanTargetsCalls++;
    if (throwScanTargets) {
      throw Exception('scan failed');
    }
    return scanTargetsResult;
  }

  @override
  Future<TargetCandidate?> scanOneTarget(
    String targetId, {
    bool enableAgentCliModelLookup = false,
  }) async {
    scanTargetsCalls++;
    scanOneTargetCalls++;
    scannedOneTargetIds.add(targetId);
    catalogLookups.add(enableAgentCliModelLookup);
    if (throwScanTargets) {
      throw Exception('scan failed');
    }
    final id = targetId.trim();
    for (final target in scanTargetsResult) {
      if (target.target == id) {
        return target;
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> inspectTarget(String target) async {
    inspectTargetCalls++;
    if (throwInspectTarget) {
      throw Exception('inspect failed');
    }
    return {'target': target};
  }

  @override
  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
    String location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
  }) async {
    addTargetCalls++;
    if (throwAddTarget) {
      throw Exception('add failed');
    }
    addedTarget = target;
    addedConfigPath = configPath;
    addedHistoryRoot = historyRoot;
    scanTargetsCalls++;
    return {'ok': true, 'target': target};
  }

  @override
  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId) async {
    restoreSnapshotCount++;
    if (throwRestoreSnapshot) {
      throw Exception('restore failed');
    }
    restoredSnapshotId = snapshotId;
    return {'ok': true, 'snapshotId': snapshotId};
  }

  @override
  Future<List<Map<String, dynamic>>> listSnapshots({String target = ''}) async {
    listSnapshotsCalls++;
    return snapshots;
  }

  @override
  Future<List<Map<String, dynamic>>> listPairings({String agent = ''}) async {
    listPairingsCalls++;
    if (throwListPairings) {
      throw Exception('listPairings failed');
    }
    if (agent.isNotEmpty && pairedAgent.isEmpty) {
      return pairings.map((pairing) {
        final updated = Map<String, dynamic>.from(pairing);
        updated['agentId'] = agent;
        return updated;
      }).toList();
    }
    return pairings;
  }

  @override
  Future<Map<String, dynamic>> requestPairing({
    required String agent,
    String target = '',
  }) async {
    requestPairingCalls++;
    pairedAgent = agent;
    requestSkillHubCalls++;
    pairingStatus = 'requested';
    return {...pairingResult, 'agent': agent};
  }

  @override
  Future<Map<String, dynamic>> approvePairing({required String agent}) async {
    approvePairingCalls++;
    pairedAgent = agent;
    pairingStatus = 'approved';
    return {...pairingResult, 'status': pairingStatus};
  }

  @override
  Future<Map<String, dynamic>> revokePairing({required String agent}) async {
    revokePairingCalls++;
    if (skillBusyGate != null) {
      await skillBusyGate!.future;
    }
    pairingStatus = 'revoked';
    return {...pairingResult, 'status': pairingStatus};
  }

  @override
  Future<List<Map<String, dynamic>>> listSkills({required String agent}) async {
    listSkillsCalls++;
    if (throwListSkills) {
      throw Exception('listSkills failed');
    }
    if (skillHubPairingsRequiresRefresh) {
      return [];
    }
    return skills;
  }

  bool skillHubPairingsRequiresRefresh = false;

  @override
  Future<Map<String, dynamic>> ensureOpencodeServe({
    int port = 24173,
    String? executable,
    String? attachUrl,
  }) async {
    ensureOpencodeServeCalls++;
    return {
      ...opencodeServeStatusResult,
      'port': port,
      'executable': ?executable,
      'attachUrl': ?attachUrl,
    };
  }

  @override
  Future<Map<String, dynamic>> stopOpencodeServe() async {
    stopOpencodeServeCalls++;
    opencodeServeStatusResult = {
      'ok': true,
      'status': 'stopped',
      'running': false,
      'healthy': false,
      'attachUrl': 'http://127.0.0.1:24173',
      'port': 24173,
    };
    return opencodeServeStatusResult;
  }

  String fakeAgentArgValue(
    List<String> args,
    String flag, {
    String fallback = '',
  }) {
    final index = args.indexOf(flag);
    if (index < 0 || index + 1 >= args.length) {
      return fallback;
    }
    return args[index + 1];
  }
}
