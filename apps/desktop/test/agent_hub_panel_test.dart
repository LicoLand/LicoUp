import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_engine.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _ids = [
  'codex',
  'cursor',
  'opencode',
  'claude-code',
  'pi',
  'openclaw',
  'hermes',
  'antigravity',
];

const _summaries = {
  'codex':
      'Codex CLI is a coding agent from OpenAI that runs locally on your computer. Inspect code, make changes, run commands, and automate repeatable work without leaving your terminal.',
  'cursor':
      'Cursor is the AI code editor. The Cursor Agent CLI brings that agent to the terminal so you can write, review, and ship code from the command line without leaving the shell.',
  'opencode':
      'OpenCode is an open source AI coding agent. It is available as a terminal-based interface, desktop app, or IDE extension, and works with the model providers you already use.',
  'claude-code':
      'Claude Code is an agentic coding tool that reads your codebase, edits files, runs commands, and integrates with your development tools. Available in your terminal, IDE, desktop app, and browser.',
  'pi':
      'Pi is a minimal agent harness. Adapt Pi to your workflows, not the other way around. Customize it with extensions, skills, prompt templates, and themes, then share them as packages.',
  'openclaw':
      'OpenClaw is a self-hosted personal AI assistant that connects to the apps you already use. Run it on this machine or a virtual machine and keep the setup under your control.',
  'hermes':
      'Hermes Agent is the self-improving AI agent built by Nous Research. It creates skills from experience, improves them during use, and can run locally or on a virtual machine.',
  'antigravity':
      'Google Antigravity is an agent-first development environment. The Antigravity CLI lets you run that agent from the terminal to build, inspect, and ship software.',
};

const _homepages = {
  'codex': 'https://developers.openai.com/codex',
  'cursor': 'https://cursor.com',
  'opencode': 'https://opencode.ai',
  'claude-code': 'https://claude.com/product/claude-code',
  'pi': 'https://pi.dev',
  'openclaw': 'https://openclaw.ai',
  'hermes': 'https://hermes-agent.nousresearch.com',
  'antigravity': 'https://antigravity.google',
};

String _channelKind(String id) {
  return switch (id) {
    'pi' || 'openclaw' => 'npm',
    'hermes' => 'official-artifact',
    _ => 'homebrew',
  };
}

String _title(String id) {
  return switch (id) {
    'codex' => 'Codex',
    'cursor' => 'Cursor',
    'antigravity' => 'Antigravity',
    _ => id,
  };
}

final class _FakeHubEngine implements AgentHubEnginePort {
  _FakeHubEngine({
    this.presentIds = const {},
    this.externalIds = const {},
    this.externalProtectedIds = const {},
    this.ownedIds = const {},
    this.failedIds = const {},
  });

  final Set<String> presentIds;
  final Set<String> externalIds;
  final Set<String> externalProtectedIds;
  final Set<String> ownedIds;
  final Set<String> failedIds;
  final List<AgentHubLifecycleAction> actions = [];
  String? lastRecipeId;

  @override
  Future<AgentHubCatalogSnapshot> catalog() async {
    return AgentHubCatalogSnapshot(
      recipes: [
        for (final id in _ids)
          AgentHubRecipe(
            id: id,
            displayName: _title(id),
            adaptation: id == 'antigravity'
                ? AgentHubAdaptationDepth.partial
                : AgentHubAdaptationDepth.deep,
            present: presentIds.contains(id),
            ownership: ownedIds.contains(id)
                ? 'owned'
                : externalProtectedIds.contains(id)
                ? 'external_protected'
                : externalIds.contains(id)
                ? 'external'
                : 'none',
            lifecycle: failedIds.contains(id)
                ? 'failed'
                : presentIds.contains(id)
                ? 'discovered'
                : 'absent',
            installable:
                !externalIds.contains(id) && !externalProtectedIds.contains(id),
            channelKind: _channelKind(id),
            selectedChannelKind: _channelKind(id),
            summary: _summaries[id]!,
            homepage: _homepages[id]!,
          ),
      ],
    );
  }

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) async {
    return _record(AgentHubLifecycleAction.plan, request.recipeId, 'planned');
  }

  @override
  Future<AgentHubOperationResult> confirm(
    AgentHubConfirmRequest request,
  ) async {
    return _record(
      AgentHubLifecycleAction.confirm,
      request.recipeId,
      'confirmed',
    );
  }

  @override
  Future<AgentHubOperationResult> install(
    AgentHubInstallRequest request,
  ) async {
    return _record(
      AgentHubLifecycleAction.install,
      request.recipeId,
      'available',
      events: const [
        'planned',
        'confirmed',
        'applying',
        'verifying',
        'rescanning',
        'available',
      ],
    );
  }

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) async {
    return _record(
      AgentHubLifecycleAction.update,
      request.recipeId,
      'available',
    );
  }

  @override
  Future<AgentHubOperationResult> uninstall(
    AgentHubUninstallRequest request,
  ) async {
    return _record(
      AgentHubLifecycleAction.uninstall,
      request.recipeId,
      'uninstalled',
    );
  }

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) async {
    return _record(AgentHubLifecycleAction.verify, request.recipeId, 'absent');
  }

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) async {
    return _record(AgentHubLifecycleAction.rescan, request.recipeId, 'absent');
  }

  AgentHubOperationResult _record(
    AgentHubLifecycleAction action,
    String recipeId,
    String nativeStatus, {
    List<String> events = const [],
  }) {
    actions.add(action);
    lastRecipeId = recipeId;
    return AgentHubOperationResult(
      status: AgentHubOperationStatus.completed,
      action: action,
      recipeId: recipeId,
      nativeStatus: nativeStatus,
      events: events,
    );
  }
}

Widget _harness(
  AgentHubEnginePort engine, {
  Locale locale = const Locale('en'),
  AgentHubHomepageOpener? openHomepage,
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: LicoStrings.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    theme: buildLicoTheme(platformBrightness: Brightness.dark),
    home: Scaffold(
      body: SizedBox(
        width: 1100,
        height: 720,
        child: AgentHubPanel(
          engine: engine,
          openHomepage: openHomepage ?? (uri) async => true,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'Agent Hub renders eight native recipe cards with adaptation tags',
    (tester) async {
      await tester.pumpWidget(_harness(_FakeHubEngine()));
      await tester.pump();

      expect(find.byKey(const Key('agent-hub-panel')), findsOneWidget);
      for (final id in _ids) {
        expect(find.byKey(Key('agent-hub-card-$id')), findsOneWidget);
        expect(find.byKey(Key('agent-hub-adaptation-$id')), findsOneWidget);
        expect(find.byKey(Key('agent-hub-summary-$id')), findsOneWidget);
        expect(find.byKey(Key('agent-hub-channel-$id')), findsOneWidget);
        expect(find.byKey(Key('agent-hub-visit-$id')), findsOneWidget);
        expect(find.byKey(Key('agent-hub-update-$id')), findsOneWidget);
        expect(find.byKey(Key('agent-hub-uninstall-$id')), findsOneWidget);
        expect(find.byKey(Key('agent-hub-status-$id')), findsNothing);
        expect(find.byKey(Key('agent-hub-more-$id')), findsOneWidget);
        final summary = tester.widget<Text>(
          find.byKey(Key('agent-hub-summary-$id')),
        );
        expect(summary.maxLines, 3);
        expect(summary.overflow, TextOverflow.ellipsis);
        expect(summary.data, _summaries[id]);
      }
      expect(find.text('Deep'), findsNWidgets(7));
      expect(find.text('Partial'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('Cursor'), findsOneWidget);
      expect(find.text('Antigravity'), findsOneWidget);
      expect(find.text('brew'), findsNWidgets(5));
      expect(find.text('npm'), findsNWidgets(2));
      expect(find.text('official'), findsOneWidget);
      expect(find.text('Visit →'), findsNWidgets(8));
      expect(find.text('Update'), findsNWidgets(8));
      expect(find.text('Uninstall'), findsNWidgets(8));
      expect(find.text('Installed'), findsNothing);
      expect(find.text('Not installed'), findsNothing);
      expect(find.text('External'), findsNothing);
      expect(find.text('Failed'), findsNothing);
      expect(find.textContaining('rank'), findsNothing);
      expect(find.textContaining('Code mode'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Agent Hub Visit label follows LicoStrings locale', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(_FakeHubEngine(), locale: const Locale('zh')),
    );
    await tester.pump();
    expect(find.text('访问'), findsNWidgets(8));
    expect(find.text('更新'), findsNWidgets(8));
    expect(find.text('卸载'), findsNWidgets(8));
    expect(find.text('Visit →'), findsNothing);
    expect(find.text('外部安装'), findsNothing);
    expect(find.text('未安装'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Visit opens the official homepage through the injected opener', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      _harness(
        _FakeHubEngine(),
        openHomepage: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-hub-visit-codex')));
    await tester.pump();
    expect(opened, [Uri.parse('https://developers.openai.com/codex')]);
    expect(find.text('Unable to open homepage'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Visit fail-closed shows a visible error instead of no-op', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(_FakeHubEngine(), openHomepage: (uri) async => false),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-hub-visit-codex')));
    await tester.pump();
    expect(find.text('Unable to open homepage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overflow keeps rescan reachable without a ranking row', (
    tester,
  ) async {
    final engine = _FakeHubEngine();
    await tester.pumpWidget(_harness(engine, locale: const Locale('zh')));
    await tester.pump();
    expect(find.text('重新扫描'), findsNothing);
    await tester.tap(find.byKey(const Key('agent-hub-more-codex')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agent-hub-rescan-codex')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agent-hub-rescan-codex')));
    await tester.pump();
    expect(engine.actions, [AgentHubLifecycleAction.rescan]);
    expect(engine.lastRecipeId, 'codex');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Agent Hub panel joins plan/confirm/install/verify/rescan through the native port',
    (tester) async {
      final engine = _FakeHubEngine();
      await tester.pumpWidget(_harness(engine));
      await tester.pump();

      final panel = tester.widget<AgentHubPanel>(find.byType(AgentHubPanel));
      final plan = await panel.runLifecycle(
        AgentHubLifecycleAction.plan,
        recipeId: 'codex',
      );
      final confirm = await panel.runLifecycle(
        AgentHubLifecycleAction.confirm,
        recipeId: 'codex',
      );
      final install = await panel.runLifecycle(
        AgentHubLifecycleAction.install,
        recipeId: 'codex',
      );
      final verify = await panel.runLifecycle(
        AgentHubLifecycleAction.verify,
        recipeId: 'cursor',
      );
      final rescan = await panel.runLifecycle(
        AgentHubLifecycleAction.rescan,
        recipeId: 'opencode',
      );
      final update = await panel.runLifecycle(
        AgentHubLifecycleAction.update,
        recipeId: 'codex',
      );
      final uninstall = await panel.runLifecycle(
        AgentHubLifecycleAction.uninstall,
        recipeId: 'codex',
      );
      expect(plan.status, AgentHubOperationStatus.completed);
      expect(confirm.status, AgentHubOperationStatus.completed);
      expect(install.status, AgentHubOperationStatus.completed);
      expect(verify.status, AgentHubOperationStatus.completed);
      expect(rescan.status, AgentHubOperationStatus.completed);
      expect(update.status, AgentHubOperationStatus.completed);
      expect(uninstall.status, AgentHubOperationStatus.completed);
      expect(engine.actions, [
        AgentHubLifecycleAction.plan,
        AgentHubLifecycleAction.confirm,
        AgentHubLifecycleAction.install,
        AgentHubLifecycleAction.verify,
        AgentHubLifecycleAction.rescan,
        AgentHubLifecycleAction.update,
        AgentHubLifecycleAction.uninstall,
      ]);
    },
  );

  testWidgets(
    'Update and Uninstall pin to the card bottom-right with the chip inset',
    (tester) async {
      await tester.pumpWidget(_harness(_FakeHubEngine()));
      await tester.pump();

      final card = tester.getRect(
        find.byKey(const Key('agent-hub-card-codex')),
      );
      final chip = tester.getRect(
        find.byKey(const Key('agent-hub-channel-codex')),
      );
      final update = tester.getRect(
        find.byKey(const Key('agent-hub-update-codex')),
      );
      final uninstall = tester.getRect(
        find.byKey(const Key('agent-hub-uninstall-codex')),
      );
      final leftInset = chip.left - card.left;
      expect(card.right - uninstall.right, closeTo(leftInset, 0.5));
      expect(card.bottom - uninstall.bottom, closeTo(leftInset, 0.5));
      expect(card.bottom - chip.bottom, closeTo(leftInset, 0.5));
      expect(uninstall.left - update.right, closeTo(16, 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unwired hub engine does not render a Dart recipe catalog', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(const UnwiredAgentHubEngine()));
    await tester.pump();
    expect(find.byKey(const Key('agent-hub-card-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-catalog-failed')), findsOneWidget);
    expect(find.text('Scanning...'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'idle Hub cards show terminal presence instead of perpetual scanning',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          _FakeHubEngine(
            presentIds: const {'codex'},
            externalIds: const {'cursor'},
            failedIds: const {'pi'},
          ),
          locale: const Locale('zh'),
        ),
      );
      await tester.pump();

      expect(find.text('扫描中...'), findsNothing);
      expect(find.byKey(const Key('agent-hub-card-busy')), findsNothing);
      expect(find.text('已安装'), findsNothing);
      expect(find.text('外部安装'), findsNothing);
      expect(find.text('失败'), findsNothing);
      expect(find.text('未安装'), findsNothing);
      expect(find.text('brew'), findsNWidgets(5));
      expect(find.text('npm'), findsNWidgets(2));
      expect(find.text('official'), findsOneWidget);
      expect(find.text('重新扫描'), findsNothing);
      expect(find.byKey(const Key('agent-hub-more-codex')), findsOneWidget);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-update-cursor')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const Key('agent-hub-uninstall-cursor')),
            )
            .onTap,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'owned cards enable update and uninstall; external cards stay protected',
    (tester) async {
      final engine = _FakeHubEngine(
        presentIds: const {'codex', 'cursor', 'opencode'},
        ownedIds: const {'codex'},
        externalIds: const {'cursor'},
        externalProtectedIds: const {'opencode'},
      );
      await tester.pumpWidget(_harness(engine));
      await tester.pump();

      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-update-codex')))
            .onTap,
        isNotNull,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-uninstall-codex')))
            .onTap,
        isNotNull,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-update-cursor')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const Key('agent-hub-uninstall-cursor')),
            )
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-update-opencode')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const Key('agent-hub-uninstall-opencode')),
            )
            .onTap,
        isNull,
      );
      expect(find.text('External'), findsNothing);
      await tester.tap(find.byKey(const Key('agent-hub-update-codex')));
      await tester.pump();
      expect(engine.actions, [AgentHubLifecycleAction.update]);
      expect(engine.lastRecipeId, 'codex');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cards stay on terminal status when a later catalog never completes',
    (tester) async {
      await tester.pumpWidget(
        _harness(_FakeHubEngine(), locale: const Locale('zh')),
      );
      await tester.pump();
      expect(find.byKey(const Key('agent-hub-card-codex')), findsOneWidget);
      expect(find.text('未安装'), findsNothing);
      expect(find.text('扫描中...'), findsNothing);

      final pending = Completer<AgentHubCatalogSnapshot>();
      await tester.pumpWidget(
        _harness(
          _PendingCatalogEngine(pending.future),
          locale: const Locale('zh'),
        ),
      );
      await tester.pump();

      expect(find.text('扫描中...'), findsNothing);
      expect(find.byKey(const Key('agent-hub-card-busy')), findsNothing);
      expect(find.byKey(const Key('agent-hub-card-codex')), findsOneWidget);
      expect(find.text('未安装'), findsNothing);
      expect(find.text('外部安装'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed catalog leaves scanning and shows a failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const _FailedCatalogEngine(), locale: const Locale('zh')),
    );
    await tester.pump();

    expect(find.byKey(const Key('agent-hub-loading')), findsNothing);
    expect(find.byKey(const Key('agent-hub-catalog-failed')), findsOneWidget);
    expect(find.text('扫描中...'), findsNothing);
    expect(find.byKey(const Key('agent-hub-card-codex')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thrown catalog leaves scanning and shows a failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const _ThrowingCatalogEngine(), locale: const Locale('zh')),
    );
    await tester.pump();

    expect(find.byKey(const Key('agent-hub-catalog-failed')), findsOneWidget);
    expect(find.text('扫描中...'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

AgentHubOperationResult _stubResult(
  AgentHubLifecycleAction action,
  String recipeId,
) {
  return AgentHubOperationResult(
    status: AgentHubOperationStatus.failed,
    action: action,
    recipeId: recipeId,
    nativeStatus: 'failed',
    events: const ['failed'],
  );
}

final class _PendingCatalogEngine implements AgentHubEnginePort {
  _PendingCatalogEngine(this.catalogFuture);

  final Future<AgentHubCatalogSnapshot> catalogFuture;

  @override
  Future<AgentHubCatalogSnapshot> catalog() => catalogFuture;

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) async {
    return _stubResult(AgentHubLifecycleAction.plan, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> confirm(
    AgentHubConfirmRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.confirm, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> install(
    AgentHubInstallRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.install, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) async {
    return _stubResult(AgentHubLifecycleAction.update, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> uninstall(
    AgentHubUninstallRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.uninstall, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) async {
    return _stubResult(AgentHubLifecycleAction.verify, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) async {
    return _stubResult(AgentHubLifecycleAction.rescan, request.recipeId);
  }
}

final class _FailedCatalogEngine implements AgentHubEnginePort {
  const _FailedCatalogEngine();

  @override
  Future<AgentHubCatalogSnapshot> catalog() async {
    return const AgentHubCatalogSnapshot(recipes: [], ok: false);
  }

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) async {
    return _stubResult(AgentHubLifecycleAction.plan, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> confirm(
    AgentHubConfirmRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.confirm, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> install(
    AgentHubInstallRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.install, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) async {
    return _stubResult(AgentHubLifecycleAction.update, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> uninstall(
    AgentHubUninstallRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.uninstall, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) async {
    return _stubResult(AgentHubLifecycleAction.verify, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) async {
    return _stubResult(AgentHubLifecycleAction.rescan, request.recipeId);
  }
}

final class _ThrowingCatalogEngine implements AgentHubEnginePort {
  const _ThrowingCatalogEngine();

  @override
  Future<AgentHubCatalogSnapshot> catalog() async {
    throw StateError('native catalog failed');
  }

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) async {
    return _stubResult(AgentHubLifecycleAction.plan, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> confirm(
    AgentHubConfirmRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.confirm, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> install(
    AgentHubInstallRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.install, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) async {
    return _stubResult(AgentHubLifecycleAction.update, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> uninstall(
    AgentHubUninstallRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.uninstall, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) async {
    return _stubResult(AgentHubLifecycleAction.verify, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) async {
    return _stubResult(AgentHubLifecycleAction.rescan, request.recipeId);
  }
}
