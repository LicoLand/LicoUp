import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/features/conversations/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop create controls reach the packaged native Conversation backend',
    (tester) async {
      final cliPath = Platform.environment['LICO_CLIENT_PATH']?.trim() ?? '';
      expect(cliPath, isNotEmpty, reason: 'LICO_CLIENT_PATH is required');
      final portableRoot = await Directory.systemTemp.createTemp(
        'lico-group-button-flow-',
      );
      addTearDown(() => portableRoot.delete(recursive: true));
      final runner = _IsolatedNativeRunner(
        cliPath: cliPath,
        portableRoot: portableRoot.path,
      );
      final controller = ClientConversationController(runner: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      final captureKey = GlobalKey();

      tester.view.physicalSize = const Size(1120, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          builder: (context, child) => RepaintBoundary(
            key: captureKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: _GroupConversationButtonHarness(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(captureKey, '01-start');

      final plus = find.byTooltip('新建');
      expect(plus, findsOneWidget);
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(find.text('新对话'), findsOneWidget);
      expect(find.text('新群组'), findsOneWidget);
      await _capture(captureKey, '02-create-menu');

      await tester.tap(find.text('新对话'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('group-flow-new-conversation-open')),
        findsOne,
      );

      await tester.tap(plus);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新群组'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('canonical-group-create-dialog')), findsOne);
      await _capture(captureKey, '03-empty-group-dialog');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('canonical-group-create-dialog')),
        findsNothing,
      );

      await tester.tap(plus);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新群组'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('canonical-group-title-field')),
        '产品讨论',
      );
      await tester.tap(find.byKey(const Key('canonical-group-member-codex')));
      await tester.pumpAndSettle();
      final confirm = tester.widget<FilledButton>(
        find.byKey(const Key('canonical-group-create-confirm')),
      );
      expect(confirm.onPressed, isNotNull);
      await _capture(captureKey, '04-group-ready');

      await tester.tap(find.byKey(const Key('canonical-group-create-confirm')));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await _capture(captureKey, '05-group-creating');
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('canonical-group-create-dialog'))
            .evaluate()
            .isEmpty,
      );

      expect(controller.groupConversations, hasLength(1));
      expect(controller.selectedConversation?.group, isTrue);
      expect(controller.selectedConversation?.activeMemberships, hasLength(2));
      expect(
        find.byKey(
          ValueKey<String>(
            'messaging-group-conversation-${controller.selectedConversationId}',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('canonical-group-conversation-pane')),
        findsOne,
      );
      await _capture(captureKey, '06-group-created');

      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.create',
        ),
        hasLength(1),
      );
      final createRequest = runner.requests.firstWhere(
        (request) => request['action'] == 'conversation.create',
      );
      expect(
        createRequest['members'],
        isA<List<Object?>>().having((members) => members.length, 'length', 1),
      );

      await tester.tap(find.byKey(const Key('canonical-group-archive')));
      await _pumpUntil(tester, () => controller.groupConversations.isEmpty);
      expect(controller.selectedConversation, isNull);
      await _capture(captureKey, '07-group-archived');
      expect(tester.takeException(), isNull);
    },
  );
}

class _GroupConversationButtonHarness extends StatefulWidget {
  const _GroupConversationButtonHarness({required this.controller});

  final ClientConversationController controller;

  @override
  State<_GroupConversationButtonHarness> createState() =>
      _GroupConversationButtonHarnessState();
}

class _GroupConversationButtonHarnessState
    extends State<_GroupConversationButtonHarness> {
  var _newConversationOpen = false;

  static final _targets = <TargetCandidate>[
    TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: '/synthetic/codex',
      adapterStatus: 'implemented',
      adapterCapabilities: const {'conversationDriver': 'native'},
    ),
    TargetCandidate(
      target: 'claude-code',
      label: 'Claude Code',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: '/synthetic/claude',
      adapterStatus: 'implemented',
      adapterCapabilities: const {'conversationDriver': 'native'},
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => Row(
          children: [
            SizedBox(
              width: 320,
              child: MessagingContactList(
                targets: _targets,
                sessionsByAgent:
                    const <String, List<AgentConversationSession>>{},
                selectedAgentId: 'codex',
                activityFor: (_) => AgentConversationTabActivity.none,
                onSelectAgent: (_) {},
                onNewConversation: () {
                  widget.controller.clearSelection();
                  setState(() => _newConversationOpen = true);
                },
                groupConversations: widget.controller.groupConversations,
                selectedGroupConversationId:
                    widget.controller.selectedConversationId,
                onSelectGroupConversation: (conversationId) => unawaited(
                  widget.controller.selectConversation(conversationId),
                ),
                onNewGroupConversation: () => unawaited(
                  showCreateCanonicalGroupConversationDialog(
                    context: context,
                    controller: widget.controller,
                    targets: _targets,
                  ),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: widget.controller.selectedConversation == null
                  ? Center(
                      child: Text(
                        _newConversationOpen ? '新对话已打开' : '选择一个对话',
                        key: _newConversationOpen
                            ? const Key('group-flow-new-conversation-open')
                            : null,
                      ),
                    )
                  : CanonicalGroupConversationPane(
                      controller: widget.controller,
                      targets: _targets,
                      onCopyText: (_) async {},
                      framed: false,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _IsolatedNativeRunner implements AgentCommandRunner {
  _IsolatedNativeRunner({required this.cliPath, required this.portableRoot});

  final String cliPath;
  final String portableRoot;
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnsupportedError('runCli is not used by this acceptance');

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final decodedRequest = jsonDecode(stdinText);
    if (decodedRequest is! Map) throw StateError('request_invalid');
    final request = Map<String, dynamic>.from(decodedRequest);
    requests.add(request);
    if (request['action'] == 'conversation.create') {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final process = await Process.start(
      cliPath,
      args,
      environment: {
        ...Platform.environment,
        'LICOUP_PORTABLE_DIR': portableRoot,
      },
      runInShell: false,
    );
    final stdout = utf8.decoder.bind(process.stdout).join();
    final stderr = process.stderr.drain<void>();
    process.stdin.write(stdinText);
    await process.stdin.close();
    final results = await Future.wait<dynamic>([
      process.exitCode,
      stdout,
      stderr,
    ]);
    if (results[0] != 0) throw StateError('native_cli_failed');
    final decoded = jsonDecode(results[1] as String);
    if (decoded is! Map) throw StateError('native_response_invalid');
    return Map<String, dynamic>.from(decoded);
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

Future<void> _capture(GlobalKey captureKey, String name) async {
  final outputRoot =
      Platform.environment['LICO_GROUP_AUDIT_OUTPUT']?.trim() ?? '';
  if (outputRoot.isEmpty) return;
  final boundary = captureKey.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) {
    throw StateError('capture_boundary_unavailable');
  }
  final image = await boundary.toImage(pixelRatio: 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('capture_failed');
  final directory = Directory(outputRoot);
  await directory.create(recursive: true);
  await File(
    '${directory.path}/$name.png',
  ).writeAsBytes(data.buffer.asUint8List(), flush: true);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}
