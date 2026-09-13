import 'dart:async';

import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_status.dart';
import 'package:licoup/src/contracts/skill_hub.dart';
import 'package:licoup/src/contracts/skill_hub_preferences.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
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

  test(
    'ready skills publish before local scan and other Agents finish',
    () async {
      final local = Completer<void>();
      final opencode = Completer<void>();
      final controller = _controller(
        gateway: _Gateway(
          skillsByAgent: {
            'codex': [
              {'skillId': 'codex-review'},
            ],
            'opencode': [
              {'skillId': 'opencode-debug'},
            ],
          },
          skillGates: {'opencode': opencode},
        ),
        source: _Source([
          {'skillId': 'shared-format', 'isPublic': true},
        ], gate: local),
      );
      addTearDown(controller.dispose);
      final refresh = controller.refresh('codex');
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);
      expect(
        controller.skills.map((skill) => skill['skillId']),
        contains('codex-review'),
      );
      local.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);
      expect(
        controller.skills.map((skill) => skill['skillId']),
        containsAll(['codex-review', 'shared-format']),
      );
      opencode.complete();
      await refresh;
      expect(controller.busy, isFalse);
      expect(
        controller.skills.map((skill) => skill['skillId']),
        containsAll(['codex-review', 'shared-format', 'opencode-debug']),
      );
    },
  );

  test('a failed source preserves its last available skills', () async {
    final gateway = _Gateway(
      skillsByAgent: {
        'codex': [
          {'skillId': 'review'},
        ],
        'opencode': [
          {'skillId': 'debug'},
        ],
      },
    );
    final controller = _controller(gateway: gateway);
    addTearDown(controller.dispose);
    await controller.refresh('codex');
    gateway.failingAgents.add('opencode');
    await controller.refresh('codex', forceRefresh: true);
    expect(
      controller.skills.map((skill) => skill['skillId']),
      containsAll(['review', 'debug']),
    );
    expect(controller.lastErrorCode, isEmpty);
  });

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

  test('local visual preferences persist through their narrow port', () async {
    final preferences = _PreferencesRepository();
    final controller = _controller(
      gateway: _Gateway(),
      preferences: preferences,
    );
    addTearDown(controller.dispose);

    await controller.updateVisualOverride(
      skillId: 'review',
      iconId: 'sparkles',
    );
    expect(preferences.saved.overrideFor('review').iconId, 'sparkles');
  });
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
  const _Source(this.values, {this.gate});

  final Completer<void>? gate;

  final List<Map<String, dynamic>> values;

  @override
  Future<List<Map<String, dynamic>>> scan({
    required Iterable<String> detectedAgentIds,
  }) async {
    if (gate != null) await gate!.future;
    return values;
  }
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
    this.skillGates = const {},
  }) : failingAgents = failingAgents ?? <String>{};

  final Map<String, List<Map<String, dynamic>>> skillsByAgent;
  final Set<String> failingAgents;
  final Completer<void>? gate;
  final Map<String, Completer<void>> skillGates;
  var requestCalls = 0;

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
    final skillGate = skillGates[agent];
    if (skillGate != null) await skillGate.future;
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
}
