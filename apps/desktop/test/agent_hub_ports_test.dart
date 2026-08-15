import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_capability_port.dart';
import 'package:licoup/src/application/features/agent_hub/agent_hub_engine.dart';
import 'package:licoup/src/contracts/agent_hub.dart';

const _ids = [
  'codex',
  'cursor',
  'opencode',
  'claude-code',
  'pi',
  'openclaw',
  'hermes',
  'antigravity',
  'deepseek-harness',
];

List<Map<String, dynamic>> _nativeCards() {
  return [
    for (var index = 0; index < _ids.length; index++)
      <String, dynamic>{
        'id': _ids[index],
        'label': _title(_ids[index]),
        'adaptation': switch (_ids[index]) {
          'antigravity' => 'partial',
          'deepseek-harness' => 'pending-evaluation',
          _ => 'deep',
        },
        'present': false,
        'ownership': 'none',
        'lifecycle': 'absent',
        'primaryAction': 'install',
        'installable': true,
        'selectedChannelKind': _channelKind(_ids[index]),
        'channelKind': _channelKind(_ids[index]),
        'summary': _summary(_ids[index]),
        'homepage': _homepage(_ids[index]),
        'installedVersion': '',
        'latestVersion': '',
        'updateAvailable': false,
        'version': '',
        'installChannels': [
          {
            'id': _channelKind(_ids[index]),
            'kind': _channelKind(_ids[index]),
            'versionPolicy': 'latest',
          },
        ],
      },
  ];
}

String _channelKind(String id) {
  return switch (id) {
    'pi' || 'openclaw' || 'deepseek-harness' => 'npm',
    'hermes' => 'official-artifact',
    _ => 'homebrew',
  };
}

String _summary(String id) {
  return '$id official product copy that occupies three muted description lines and then ellipsizes.';
}

String _homepage(String id) {
  return switch (id) {
    'codex' => 'https://developers.openai.com/codex',
    'cursor' => 'https://cursor.com',
    'opencode' => 'https://opencode.ai',
    'claude-code' => 'https://claude.com/product/claude-code',
    'pi' => 'https://pi.dev',
    'openclaw' => 'https://openclaw.ai',
    'hermes' => 'https://hermes-agent.nousresearch.com',
    'antigravity' => 'https://antigravity.google',
    'deepseek-harness' => 'https://deepseek.com/harness/en/',
    _ => 'https://example.invalid',
  };
}

String _title(String id) {
  return switch (id) {
    'claude-code' => 'Claude Code',
    'opencode' => 'OpenCode',
    'openclaw' => 'OpenClaw',
    'hermes' => 'Hermes Agent',
    'pi' => 'Pi Agent',
    'codex' => 'Codex',
    'cursor' => 'Cursor',
    'deepseek-harness' => 'DeepSeek Harness',
    _ => id,
  };
}

void main() {
  test(
    'native engine projects warehouse cards without a Dart catalog',
    () async {
      final calls = <List<String>>[];
      final engine = NativeAgentHubEngine(
        invoke: (arguments) async {
          calls.add(List<String>.from(arguments));
          expect(arguments.first, 'agent-hub');
          return <String, dynamic>{
            'ok': true,
            'scanGeneration': 4,
            'cards': _nativeCards(),
          };
        },
      );
      final snapshot = await engine.catalog();
      expect(snapshot.ok, isTrue);
      expect(snapshot.recipes, hasLength(_ids.length));
      expect(snapshot.recipes.map((recipe) => recipe.id).toList(), _ids);
      expect(snapshot.recipes.first.summary, contains('official product copy'));
      expect(
        snapshot.recipes.first.homepage,
        'https://developers.openai.com/codex',
      );
      expect(snapshot.recipes.first.channelKind, 'homebrew');
      expect(snapshot.recipes.first.channelChipLabel, 'brew');
      expect(snapshot.recipes.first.versionLabel, isEmpty);
      expect(snapshot.recipes.first.updateAvailable, isFalse);
      expect(snapshot.recipes.first.latestVersion, isEmpty);
      expect(snapshot.recipes.first.installChannels, isNotEmpty);
      expect(engine.cachedCatalog, isNotNull);
      expect(engine.cachedCatalog!.recipes, hasLength(_ids.length));
      expect(
        snapshot.recipes
            .singleWhere((recipe) => recipe.id == 'pi')
            .channelChipLabel,
        'npm',
      );
      expect(
        snapshot.recipes
            .singleWhere((recipe) => recipe.id == 'hermes')
            .channelChipLabel,
        'official',
      );
      expect(
        snapshot.recipes
            .where(
              (recipe) => recipe.adaptation == AgentHubAdaptationDepth.deep,
            )
            .length,
        7,
      );
      expect(
        snapshot.recipes
            .singleWhere((recipe) => recipe.id == 'antigravity')
            .adaptation,
        AgentHubAdaptationDepth.partial,
      );
      expect(
        snapshot.recipes
            .singleWhere((recipe) => recipe.id == 'deepseek-harness')
            .adaptation,
        AgentHubAdaptationDepth.pendingEvaluation,
      );
      expect(calls, [
        ['agent-hub', 'catalog'],
      ]);
    },
  );

  test('native card projects installed version and updateAvailable flag', () {
    final recipe = AgentHubRecipe.fromNativeCard(<String, dynamic>{
      'id': 'codex',
      'label': 'Codex',
      'adaptation': 'deep',
      'present': true,
      'ownership': 'owned',
      'installedVersion': '0.42.1',
      'latestVersion': '0.43.0',
      'updateAvailable': true,
      'version': '0.42.1',
    });
    expect(recipe.versionLabel, '0.42.1');
    expect(recipe.latestVersion, '0.43.0');
    expect(recipe.updateAvailable, isTrue);
    expect(recipe.versionLabel.contains('latest'), isFalse);

    final unknown = AgentHubRecipe.fromNativeCard(<String, dynamic>{
      'id': 'cursor',
      'label': 'Cursor',
      'adaptation': 'deep',
      'present': true,
      'installedVersion': '',
      'latestVersion': '',
      'updateAvailable': false,
      'version': 'latest',
    });
    expect(unknown.versionLabel, isEmpty);
    expect(unknown.updateAvailable, isFalse);
  });

  test(
    'plan reuses the catalog discovery snapshot and never scans per card',
    () async {
      final stdinPayloads = <Map<String, dynamic>>[];
      final engine = NativeAgentHubEngine(
        invoke: (arguments) async {
          if (arguments[1] == 'catalog') {
            return <String, dynamic>{'ok': true, 'cards': _nativeCards()};
          }
          expect(arguments.take(4).toList(), [
            'agent-hub',
            'plan',
            '--agent-id',
            'codex',
          ]);
          final encoded = arguments[arguments.indexOf('--stdin-json') + 1];
          stdinPayloads.add(jsonDecode(encoded) as Map<String, dynamic>);
          return <String, dynamic>{
            'ok': true,
            'status': 'planned',
            'confirmation': 'agent-hub:install:codex:homebrew:token',
            'ownership': 'none',
          };
        },
      );
      await engine.catalog();
      final planned = await engine.plan(
        const AgentHubPlanRequest(recipeId: 'codex'),
      );
      expect(planned.status, AgentHubOperationStatus.completed);
      expect(planned.nativeStatus, 'planned');
      expect(stdinPayloads, hasLength(1));
      expect(stdinPayloads.single['version'], 'latest');
      final candidates = stdinPayloads.single['discoveryCandidates'] as List;
      expect(candidates, hasLength(_ids.length));
      expect(candidates.map((item) => (item as Map)['target']).toList(), _ids);
      expect(
        candidates.every(
          (item) => (item as Map).containsKey('binaryPath') == false,
        ),
        isTrue,
      );
    },
  );

  test('confirm is local and install sends the planned token once', () async {
    String? appliedConfirmation;
    final engine = NativeAgentHubEngine(
      invoke: (arguments) async {
        if (arguments[1] == 'catalog') {
          return <String, dynamic>{'ok': true, 'cards': _nativeCards()};
        }
        if (arguments[1] == 'plan') {
          return <String, dynamic>{
            'ok': true,
            'status': 'planned',
            'confirmation': 'agent-hub:install:pi:npm:token',
            'ownership': 'none',
          };
        }
        expect(arguments[1], 'apply');
        appliedConfirmation =
            arguments[arguments.indexOf('--confirmation') + 1];
        return <String, dynamic>{
          'ok': true,
          'status': 'available',
          'ownership': 'owned',
          'events': [
            {'phase': 'planned'},
            {'phase': 'confirmed'},
            {'phase': 'applying'},
            {'phase': 'verifying'},
            {'phase': 'rescanning'},
            {'phase': 'available'},
          ],
        };
      },
    );
    await engine.catalog();
    await engine.plan(const AgentHubPlanRequest(recipeId: 'pi'));
    final confirmed = await engine.confirm(
      const AgentHubConfirmRequest(recipeId: 'pi'),
    );
    expect(confirmed.status, AgentHubOperationStatus.completed);
    expect(confirmed.nativeStatus, 'confirmed');
    final installed = await engine.install(
      const AgentHubInstallRequest(recipeId: 'pi'),
    );
    expect(installed.status, AgentHubOperationStatus.completed);
    expect(appliedConfirmation, 'agent-hub:install:pi:npm:token');
    expect(installed.events, [
      'planned',
      'confirmed',
      'applying',
      'verifying',
      'rescanning',
      'available',
    ]);
  });

  test(
    'five platforms declare ordinary plan/confirm/install/verify/rescan',
    () {
      const port = StaticAgentHubCapabilityPort();
      expect(AgentHubRuntimePlatform.values, hasLength(5));
      expect(AgentHubLifecycleAction.values, [
        AgentHubLifecycleAction.plan,
        AgentHubLifecycleAction.confirm,
        AgentHubLifecycleAction.install,
        AgentHubLifecycleAction.update,
        AgentHubLifecycleAction.uninstall,
        AgentHubLifecycleAction.verify,
        AgentHubLifecycleAction.rescan,
      ]);
      for (final platform in AgentHubRuntimePlatform.values) {
        for (final action in AgentHubLifecycleAction.values) {
          expect(
            port.supports(platform: platform, action: action),
            isTrue,
            reason: '${platform.name} ${action.name}',
          );
        }
      }
    },
  );

  test('unwired engine stays typed and does not complete', () async {
    const port = UnwiredAgentHubEngine();
    final catalog = await port.catalog();
    final plan = await port.plan(const AgentHubPlanRequest(recipeId: 'codex'));
    expect(port.cachedCatalog, isNull);
    expect(catalog.recipes, isEmpty);
    expect(plan.status, AgentHubOperationStatus.nativeNotWired);
    expect(plan.ok, isFalse);
  });

  test('native engine keeps one in-memory catalog cache owner', () async {
    var catalogCalls = 0;
    final engine = NativeAgentHubEngine(
      invoke: (arguments) async {
        expect(arguments, ['agent-hub', 'catalog']);
        catalogCalls += 1;
        return <String, dynamic>{
          'ok': true,
          'scanGeneration': catalogCalls,
          'cards': _nativeCards(),
        };
      },
    );
    expect(engine.cachedCatalog, isNull);
    final first = await engine.catalog();
    expect(first.scanGeneration, 1);
    expect(engine.cachedCatalog!.scanGeneration, 1);
    final second = await engine.catalog();
    expect(second.scanGeneration, 2);
    expect(engine.cachedCatalog!.scanGeneration, 2);
    expect(catalogCalls, 2);
  });

  test(
    'catalog recipeId inspects one card and merges into the cache',
    () async {
      final calls = <List<String>>[];
      final engine = NativeAgentHubEngine(
        invoke: (arguments) async {
          calls.add(List<String>.from(arguments));
          if (arguments.contains('--agent-id')) {
            final cards = _nativeCards();
            cards[0]['present'] = true;
            cards[0]['installedVersion'] = '0.147.0';
            return <String, dynamic>{
              'ok': true,
              'cards': [cards[0]],
            };
          }
          return <String, dynamic>{'ok': true, 'cards': _nativeCards()};
        },
      );
      await engine.catalog();
      final live = await engine.catalog(recipeId: 'codex');
      expect(calls, [
        ['agent-hub', 'catalog'],
        ['agent-hub', 'catalog', '--agent-id', 'codex'],
      ]);
      expect(live.recipes, hasLength(_ids.length));
      final codex = live.recipes.singleWhere((recipe) => recipe.id == 'codex');
      expect(codex.present, isTrue);
      expect(codex.installedVersion, '0.147.0');
      expect(
        live.recipes.singleWhere((recipe) => recipe.id == 'cursor').present,
        isFalse,
      );
    },
  );

  test('plan forwards selected channel and version in stdin json', () async {
    Map<String, dynamic>? payload;
    final engine = NativeAgentHubEngine(
      invoke: (arguments) async {
        if (arguments[1] == 'catalog') {
          return <String, dynamic>{'ok': true, 'cards': _nativeCards()};
        }
        payload =
            jsonDecode(arguments[arguments.indexOf('--stdin-json') + 1])
                as Map<String, dynamic>;
        return <String, dynamic>{
          'ok': true,
          'status': 'planned',
          'confirmation': 'agent-hub:install:codex:npm:token',
          'ownership': 'none',
        };
      },
    );
    await engine.catalog();
    await engine.plan(
      const AgentHubPlanRequest(
        recipeId: 'codex',
        channelId: 'npm',
        version: 'latest',
      ),
    );
    expect(payload!['channelId'], 'npm');
    expect(payload!['version'], 'latest');
  });

  test('external installs stay protected and skip apply argv', () async {
    var applyCalls = 0;
    final engine = NativeAgentHubEngine(
      invoke: (arguments) async {
        if (arguments[1] == 'catalog') {
          final cards = _nativeCards();
          cards[2]['present'] = true;
          cards[2]['ownership'] = 'external';
          cards[2]['installable'] = false;
          cards[2]['primaryAction'] = 'open';
          return <String, dynamic>{'ok': true, 'cards': cards};
        }
        if (arguments[1] == 'plan') {
          return <String, dynamic>{
            'ok': true,
            'status': 'external_protected',
            'ownership': 'external',
          };
        }
        applyCalls += 1;
        return <String, dynamic>{'ok': false, 'status': 'failed'};
      },
    );
    final snapshot = await engine.catalog();
    expect(
      snapshot.recipes
          .singleWhere((recipe) => recipe.id == 'opencode')
          .ownership,
      'external',
    );
    expect(
      snapshot.recipes
          .singleWhere((recipe) => recipe.id == 'opencode')
          .showsManageActions,
      isTrue,
    );
    final planned = await engine.plan(
      const AgentHubPlanRequest(recipeId: 'opencode'),
    );
    expect(planned.status, AgentHubOperationStatus.externalProtected);
    expect(applyCalls, 0);
  });

  test(
    'verify and rescan report a terminal catalog status instead of scanning',
    () async {
      var catalogCalls = 0;
      final engine = NativeAgentHubEngine(
        invoke: (arguments) async {
          expect(arguments, ['agent-hub', 'catalog', '--agent-id', 'codex']);
          catalogCalls += 1;
          final cards = _nativeCards();
          cards[0]['present'] = true;
          cards[0]['lifecycle'] = 'discovered';
          return <String, dynamic>{'ok': true, 'cards': cards};
        },
      );
      final verified = await engine.verify(
        const AgentHubVerifyRequest(recipeId: 'codex'),
      );
      expect(verified.status, AgentHubOperationStatus.completed);
      expect(verified.nativeStatus, 'discovered');
      expect(verified.events, isEmpty);
      expect(verified.recipes, hasLength(_ids.length));
      final rescanned = await engine.rescan(
        const AgentHubRescanRequest(recipeId: 'codex'),
      );
      expect(rescanned.status, AgentHubOperationStatus.completed);
      expect(rescanned.nativeStatus, 'discovered');
      expect(rescanned.events, isEmpty);
      expect(catalogCalls, 2);
    },
  );

  test('failed catalog leaves verify as failed instead of scanning', () async {
    final engine = NativeAgentHubEngine(
      invoke: (arguments) async {
        return <String, dynamic>{'ok': false};
      },
    );
    final verified = await engine.verify(
      const AgentHubVerifyRequest(recipeId: 'codex'),
    );
    expect(verified.status, AgentHubOperationStatus.failed);
    expect(verified.nativeStatus, 'failed');
    expect(verified.events, ['failed']);
    expect(verified.events, isNot(contains('verifying')));
  });

  test('update plans then applies with one confirmation token', () async {
    final operations = <String>[];
    String? appliedConfirmation;
    final engine = NativeAgentHubEngine(
      invoke: (arguments) async {
        if (arguments[1] == 'catalog') {
          return <String, dynamic>{'ok': true, 'cards': _nativeCards()};
        }
        if (arguments[1] == 'plan') {
          expect(arguments[arguments.indexOf('--operation') + 1], 'update');
          operations.add('plan');
          return <String, dynamic>{
            'ok': true,
            'status': 'planned',
            'confirmation': 'agent-hub:update:codex:homebrew:token',
            'ownership': 'owned',
          };
        }
        expect(arguments[1], 'apply');
        expect(arguments[arguments.indexOf('--operation') + 1], 'update');
        operations.add('apply');
        appliedConfirmation =
            arguments[arguments.indexOf('--confirmation') + 1];
        return <String, dynamic>{
          'ok': true,
          'status': 'available',
          'ownership': 'owned',
          'events': [
            {'phase': 'planned'},
            {'phase': 'confirmed'},
            {'phase': 'applying'},
            {'phase': 'available'},
          ],
        };
      },
    );
    await engine.catalog();
    final updated = await engine.update(
      const AgentHubUpdateRequest(recipeId: 'codex'),
    );
    expect(updated.status, AgentHubOperationStatus.completed);
    expect(updated.action, AgentHubLifecycleAction.update);
    expect(operations, ['plan', 'apply']);
    expect(appliedConfirmation, 'agent-hub:update:codex:homebrew:token');
  });

  test('update and uninstall refuse external installs without apply', () async {
    var applyCalls = 0;
    final engine = NativeAgentHubEngine(
      invoke: (arguments) async {
        if (arguments[1] == 'catalog') {
          return <String, dynamic>{'ok': true, 'cards': _nativeCards()};
        }
        if (arguments[1] == 'plan') {
          return <String, dynamic>{
            'ok': false,
            'status': 'external_protected',
            'ownership': 'external',
          };
        }
        applyCalls += 1;
        return <String, dynamic>{'ok': false, 'status': 'failed'};
      },
    );
    await engine.catalog();
    final updated = await engine.update(
      const AgentHubUpdateRequest(recipeId: 'cursor'),
    );
    final uninstalled = await engine.uninstall(
      const AgentHubUninstallRequest(recipeId: 'cursor'),
    );
    expect(updated.status, AgentHubOperationStatus.externalProtected);
    expect(updated.action, AgentHubLifecycleAction.update);
    expect(uninstalled.status, AgentHubOperationStatus.externalProtected);
    expect(uninstalled.action, AgentHubLifecycleAction.uninstall);
    expect(applyCalls, 0);
  });
}
