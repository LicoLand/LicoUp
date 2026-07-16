import 'dart:async';

import 'package:flutter_client/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_hub_status.dart';
import 'package:flutter_client/src/contracts/skill_hub.dart';
import 'package:flutter_client/src/contracts/skill_hub_preferences.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'refresh merges local and native catalog with agent attribution',
    () async {
      final gateway = _Gateway(
        skillsByAgent: {
          'codex': [
            {'skillId': 'review', 'description': 'native'},
          ],
          'opencode': [
            {'skillId': 'review'},
            {'skillId': 'debug'},
          ],
        },
      );
      final controller = _controller(
        gateway: gateway,
        source: _Source([
          {
            'skillId': 'review',
            'title': 'Review',
            'isPublic': true,
            'path': '<portable-root>/.agents/skills/review',
          },
        ]),
      );
      addTearDown(controller.dispose);

      await controller.refresh('codex');

      expect(controller.pairings, hasLength(2));
      expect(controller.skills.map((skill) => skill['skillId']).toSet(), {
        'review',
        'debug',
      });
      final review = controller.skills.firstWhere(
        (skill) => skill['skillId'] == 'review',
      );
      expect(review['usedByAgents'], containsAll(['codex', 'opencode']));
      expect(controller.actionResult?['skills'], 2);
    },
  );

  test(
    'refresh isolates non-selected failures but selected failure is stable',
    () async {
      final updates = <SkillHubStatusUpdate>[];
      final gateway = _Gateway(failingAgents: {'opencode'});
      final controller = _controller(gateway: gateway, updates: updates);
      addTearDown(controller.dispose);

      await controller.refresh('codex');
      expect(controller.lastErrorCode, isEmpty);
      expect(controller.pairings, hasLength(1));

      gateway.failingAgents.add('codex');
      await controller.refresh('codex');
      expect(controller.lastErrorCode, 'skill_hub_operation_failed');
      expect(updates.last.errorCode, 'skill_hub_operation_failed');
      expect(updates.last.english, isNot(contains('private-runtime-detail')));
    },
  );

  test('busy lock suppresses duplicate workflow execution', () async {
    final gate = Completer<void>();
    final gateway = _Gateway(gate: gate);
    final controller = _controller(gateway: gateway);
    addTearDown(controller.dispose);

    unawaited(controller.requestPairing('codex'));
    await Future<void>.delayed(Duration.zero);
    await controller.requestPairing('codex');
    expect(gateway.requestCalls, 1);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'install lifecycle and preferences persist through narrow ports',
    () async {
      final gateway = _Gateway();
      final preferences = _PreferencesRepository();
      final controller = _controller(
        gateway: gateway,
        preferences: preferences,
      );
      addTearDown(controller.dispose);

      await controller.previewInstall(
        agent: 'codex',
        url: 'https://example.invalid/skill',
      );
      expect(controller.installPlan?['status'], 'planned');

      await controller.installFromGitHub(
        agent: 'codex',
        url: 'https://example.invalid/skill',
        pin: true,
      );
      expect(controller.installResult?['status'], 'installed');
      expect(gateway.lastPin, isTrue);

      await controller.rollbackInstall(
        agent: 'codex',
        snapshotId: 'snapshot-1',
      );
      expect(controller.installResult?['status'], 'rolled_back');

      await controller.updateVisualOverride(
        skillId: 'review',
        iconId: 'sparkles',
      );
      expect(preferences.saved.overrideFor('review').iconId, 'sparkles');
    },
  );
}

SkillHubController _controller({
  required _Gateway gateway,
  SkillHubLocalCatalogSource source = const _Source([]),
  _PreferencesRepository? preferences,
  List<SkillHubStatusUpdate>? updates,
}) {
  return SkillHubController(
    gateway: gateway,
    preferencesRepository: preferences ?? _PreferencesRepository(),
    localCatalogSource: source,
    portableData: Object(),
    targets: () => [_target('codex'), _target('opencode')],
    ensureTargets: () async {},
    onStatus: updates?.add ?? (_) {},
  );
}

TargetCandidate _target(String id) => TargetCandidate(
  target: id,
  label: id,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'ready',
);

class _Source implements SkillHubLocalCatalogSource {
  const _Source(this.values);

  final List<Map<String, dynamic>> values;

  @override
  Future<List<Map<String, dynamic>>> scan({
    required Iterable<String> detectedAgentIds,
  }) async => values;
}

class _PreferencesRepository implements SkillHubPreferencesRepository {
  SkillHubPreferences saved = SkillHubPreferences.defaults();

  @override
  Future<SkillHubPreferences> load(Object portableData) async => saved;

  @override
  Future<void> save(
    Object portableData,
    SkillHubPreferences preferences,
  ) async {
    saved = preferences;
  }
}

class _Gateway implements SkillHubGateway {
  _Gateway({
    this.skillsByAgent = const {},
    Set<String>? failingAgents,
    this.gate,
  }) : failingAgents = failingAgents ?? <String>{};

  final Map<String, List<Map<String, dynamic>>> skillsByAgent;
  final Set<String> failingAgents;
  final Completer<void>? gate;
  var requestCalls = 0;
  var lastPin = false;

  void _check(String agent) {
    if (failingAgents.contains(agent)) {
      throw StateError('private-runtime-detail');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> listPairings({String agent = ''}) async {
    _check(agent);
    return [
      {'agentId': agent, 'status': 'approved'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> listSkills({required String agent}) async {
    _check(agent);
    return skillsByAgent[agent] ?? const [];
  }

  @override
  Future<Map<String, dynamic>> requestPairing({
    required String agent,
    String target = '',
  }) async {
    requestCalls += 1;
    if (gate != null) await gate!.future;
    return {'ok': true, 'agent': agent};
  }

  @override
  Future<Map<String, dynamic>> approvePairing({required String agent}) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> revokePairing({required String agent}) async => {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> planSkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
  }) async => {'ok': true, 'status': 'planned', 'skillId': 'review'};

  @override
  Future<Map<String, dynamic>> applySkillInstall({
    required String agent,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
    String name = '',
    bool overwrite = false,
    bool pin = false,
  }) async {
    lastPin = pin;
    return {'ok': true, 'status': 'installed', 'skillId': 'review'};
  }

  @override
  Future<Map<String, dynamic>> rollbackSkillInstall({
    required String agent,
    required String snapshotId,
  }) async => {'ok': true, 'status': 'rolled_back'};
}
