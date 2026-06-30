import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_client/src/controllers/future_client_controller.dart';
import 'package:flutter_client/src/services/agent_service.dart';

class MockAgentService extends AgentService {
  List<String> lastArgs = [];
  Map<String, dynamic> mockResponse = {'ok': true};
  List<Map<String, dynamic>> mockSnapshots = [];
  List<TargetCandidate> mockTargets = [];

  MockAgentService() : super(runCliExecutable: null);

  @override
  Future<List<Map<String, dynamic>>> listSnapshots({String target = ''}) async {
    return mockSnapshots;
  }

  @override
  Future<List<TargetCandidate>> scanTargets() async {
    return mockTargets;
  }

  @override
  Future<Map<String, dynamic>> rollbackMcpPlugin({
    required String target,
    required String snapshotId,
    String configPath = '',
  }) async {
    lastArgs = [
      'mcp',
      'plugin',
      'rollback',
      '--target',
      target,
      '--snapshot-id',
      snapshotId,
    ];
    return mockResponse;
  }
}

TargetCandidate makeTarget({
  String target = 'opencode',
  String adapterStatus = 'implemented',
  List<String>? supportedActions,
}) {
  return TargetCandidate(
    target: target,
    label: target,
    kind: 'editor',
    status: 'found',
    configured: true,
    confidence: 1.0,
    adapterStatus: adapterStatus,
    supportedActions:
        supportedActions ??
        ['mcp.plugin.status', 'mcp.plugin.update', 'mcp.plugin.rollback'],
  );
}

void main() {
  group('McpPluginActions Rollback Latest', () {
    late FutureClientController controller;
    late MockAgentService mockService;
    late TargetCandidate dummyTarget;

    setUp(() {
      mockService = MockAgentService();
      controller = FutureClientController(agentService: mockService);

      dummyTarget = TargetCandidate(
        target: 'opencode',
        label: 'OpenCode',
        kind: 'editor',
        status: 'found',
        configured: true,
        confidence: 1.0,
        adapterStatus: 'implemented',
        supportedActions: [
          'mcp.plugin.status',
          'mcp.plugin.update',
          'mcp.plugin.rollback',
        ],
      );
    });

    test(
      'rollbackLatestMcpPlugin selects the most recent snapshot regardless of order',
      () async {
        mockService.mockSnapshots = [
          {'snapshotId': 'old-snap', 'capturedAt': '2020-01-01T10:00:00Z'},
          {'snapshotId': 'new-snap', 'capturedAt': '2026-06-08T12:00:00Z'},
          {'snapshotId': 'mid-snap', 'capturedAt': '2023-05-05T08:00:00Z'},
        ];

        await controller.rollbackLatestMcpPlugin(dummyTarget);

        expect(mockService.lastArgs.contains('new-snap'), isTrue);
      },
    );

    test(
      'rollbackLatestMcpPlugin handles missing capturedAt gracefully',
      () async {
        mockService.mockSnapshots = [
          {'snapshotId': 'no-date-1'},
          {'snapshotId': 'new-snap', 'capturedAt': '2026-06-08T12:00:00Z'},
          {'snapshotId': 'no-date-2', 'capturedAt': ''},
        ];

        await controller.rollbackLatestMcpPlugin(dummyTarget);

        expect(mockService.lastArgs.contains('new-snap'), isTrue);
      },
    );

    test(
      'rollbackLatestMcpPlugin throws clear error when no snapshots',
      () async {
        mockService.mockSnapshots = [];

        await controller.rollbackLatestMcpPlugin(dummyTarget);

        expect(
          controller.lastError,
          contains('No snapshot found for target: opencode'),
        );
      },
    );
  });

  group('McpPluginActions Capability Checks', () {
    late FutureClientController controller;
    late MockAgentService mockService;

    setUp(() {
      mockService = MockAgentService();
      controller = FutureClientController(agentService: mockService);
    });

    test('updateMcpPlugin sets error for unsupported target', () async {
      final unsupported = makeTarget(
        target: 'codex',
        adapterStatus: 'partial',
        supportedActions: ['mcp.plugin.status', 'mcp.config.plan'],
      );
      mockService.mockResponse = {'ok': true};

      await controller.updateMcpPlugin(unsupported);

      expect(controller.lastError, isNotEmpty);
      expect(controller.lastError, contains('does not support'));
    });

    test('rollbackLatestMcpPlugin sets error for unsupported target', () async {
      final unsupported = makeTarget(
        target: 'codex',
        adapterStatus: 'partial',
        supportedActions: ['mcp.plugin.status'],
      );
      mockService.mockResponse = {'ok': true};

      await controller.rollbackLatestMcpPlugin(unsupported);

      expect(controller.lastError, isNotEmpty);
      expect(controller.lastError, contains('does not support'));
    });

    test('updateMcpPlugin result ok false sets lastError', () async {
      mockService.mockResponse = {
        'ok': false,
        'status': 'verification_required',
      };
      // Override internal behavior for updateMcpPlugin
      final mockService2 = MockAgentServiceWithResponse(
        updateResponse: {'ok': false, 'status': 'verification_required'},
      );
      final ctrl = FutureClientController(agentService: mockService2);

      final supported = makeTarget();
      await ctrl.updateMcpPlugin(supported);

      expect(ctrl.lastError, isNotEmpty);
      expect(ctrl.lastError, contains('verification_required'));
      expect(ctrl.statusMessage, isNot(contains('已更新')));
    });

    test('updateMcpPlugin result ok true shows success', () async {
      mockService.mockResponse = {'ok': true, 'status': 'updated'};
      final mockService2 = MockAgentServiceWithResponse(
        updateResponse: {'ok': true, 'status': 'updated'},
      );
      final ctrl = FutureClientController(agentService: mockService2);

      final supported = makeTarget();
      await ctrl.updateMcpPlugin(supported);

      expect(ctrl.lastError, isEmpty);
    });
  });

  group('TargetCandidate Parsing', () {
    test('fromJson parses adapterCapabilities and supportedActions', () {
      final json = {
        'target': 'opencode',
        'label': 'OpenCode',
        'kind': 'cli',
        'status': 'detected',
        'configured': true,
        'confidence': 0.9,
        'adapterStatus': 'implemented',
        'adapterCapabilities': {
          'detection': 'implemented',
          'configApply': 'implemented',
          'configPlan': 'implemented',
        },
        'supportedActions': [
          'mcp.plugin.status',
          'mcp.plugin.update',
          'mcp.plugin.rollback',
        ],
      };

      final candidate = TargetCandidate.fromJson(json);

      expect(candidate.canUpdateMcpPlugin, true);
      expect(candidate.canRollbackMcpPlugin, true);
      expect(candidate.supportsAction('mcp.plugin.update'), true);
      expect(candidate.supportsAction('mcp.plugin.rollback'), true);
      expect(candidate.supportsAction('nonexistent'), false);
    });

    test('unsupported target cannot update or rollback', () {
      final candidate = makeTarget(
        adapterStatus: 'partial',
        supportedActions: ['mcp.plugin.status'],
      );

      expect(candidate.canUpdateMcpPlugin, false);
      expect(candidate.canRollbackMcpPlugin, false);
    });

    test(
      'fromJson handles missing adapterCapabilities and supportedActions',
      () {
        final json = {
          'target': 'opencode',
          'label': 'OpenCode',
          'kind': 'cli',
          'status': 'detected',
          'configured': true,
          'confidence': 0.9,
          'adapterStatus': 'implemented',
        };

        final candidate = TargetCandidate.fromJson(json);

        expect(candidate.adapterCapabilities, isEmpty);
        expect(candidate.supportedActions, isEmpty);
        expect(candidate.canUpdateMcpPlugin, false);
        expect(candidate.canRollbackMcpPlugin, false);
      },
    );
  });
}

class MockAgentServiceWithResponse extends MockAgentService {
  final Map<String, dynamic>? updateResponse;

  MockAgentServiceWithResponse({this.updateResponse});

  @override
  Future<Map<String, dynamic>> updateMcpPlugin({
    required String target,
    String configPath = '',
  }) async {
    lastArgs = ['mcp', 'plugin', 'update', '--target', target];
    return updateResponse ?? {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> mcpPluginStatus({
    required String target,
    String configPath = '',
  }) async {
    return {'ok': true, 'status': 'configured'};
  }
}
