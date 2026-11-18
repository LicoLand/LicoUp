import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/presentation/composer_drafts.dart';
import 'package:licoup/src/platform/presentation/composer_draft_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

Future<File> composerDraftFile(PortableDataRoot portableData) async {
  final dataDir = await portableData.clientDirectory();
  return File('${dataDir.path}/composer-drafts.json');
}

Future<String> composerDraftDocument(PortableDataRoot portableData) async {
  final file = await composerDraftFile(portableData);
  if (!await file.exists()) return '';
  return file.readAsString();
}

/// Unsent composer text is the user's own typing. These tests use a disposable
/// data root and never read or write the developer's real `~/.lico-up`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late PortableDataRoot portableData;
  final controllers = <ClientController>[];
  final compositions = <ConversationFeatureComposition>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lico-composer-draft-');
    portableData = PortableDataRoot(dataDirectoryOverride: directory);
  });

  tearDown(() async {
    for (final composition in compositions) {
      await composition.close();
    }
    for (final controller in controllers) {
      await controller.close();
    }
    compositions.clear();
    controllers.clear();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  ClientController newController({FakeAgentService? agentService}) {
    final controller = ClientController(
      portableData: portableData,
      agentService: agentService ?? FakeAgentService(),
      pendingNoticePollInterval: const Duration(hours: 1),
    );
    controllers.add(controller);
    return controller;
  }

  test(
    'unsent composer text typed through the composer intent survives a relaunch',
    () async {
      const scope = 'conversation:lico-group-default';
      final first = newController();
      await first.initialize();
      final composition = ConversationFeatureComposition(first);
      compositions.add(composition);

      composition.binding.intents.send(
        const UpdateConversationDraft(scope, 'unsent synthetic text'),
      );
      await first.conversationPresentationSignals.flushComposerDrafts();

      expect(
        first.conversationPresentationSignals.composerDraftFor(scope),
        'unsent synthetic text',
      );
      expect(
        await composerDraftDocument(portableData),
        contains('unsent synthetic text'),
        reason: 'the draft must reach the client data root, not only memory',
      );

      // A relaunch builds a new controller and a new signals object over the
      // same data root; nothing from the first process is reused.
      final second = newController();
      await second.initialize();

      expect(
        second.conversationPresentationSignals.composerDraftFor(scope),
        'unsent synthetic text',
      );
    },
  );

  test('each conversation keeps its own restored draft', () async {
    final first = newController();
    await first.initialize();

    first.conversationPresentationSignals
      ..replaceComposerDraft('session:codex:one', 'first draft')
      ..replaceComposerDraft('session:codex:two', 'second draft');
    await first.conversationPresentationSignals.flushComposerDrafts();

    final second = newController();
    await second.initialize();

    expect(
      second.conversationPresentationSignals.composerDraftFor(
        'session:codex:one',
      ),
      'first draft',
    );
    expect(
      second.conversationPresentationSignals.composerDraftFor(
        'session:codex:two',
      ),
      'second draft',
    );
    expect(
      second.conversationPresentationSignals.composerDraftFor(
        'session:claude-code:one',
      ),
      isEmpty,
    );
  });

  test('a sent draft stays cleared after a relaunch', () async {
    const scope = 'conversation:lico-group-default';
    final first = newController();
    await first.initialize();
    final composition = ConversationFeatureComposition(first);
    compositions.add(composition);

    composition.binding.intents.send(
      const UpdateConversationDraft(scope, 'sent synthetic text'),
    );
    await first.conversationPresentationSignals.flushComposerDrafts();

    composition.binding.intents.send(const UpdateConversationDraft(scope, ''));
    await first.conversationPresentationSignals.flushComposerDrafts();
    expect(
      await composerDraftDocument(portableData),
      isNot(contains('sent synthetic')),
    );

    final second = newController();
    await second.initialize();

    expect(
      second.conversationPresentationSignals.composerDraftFor(scope),
      isEmpty,
    );
  });

  test(
    'an unreadable document is preserved and drafts stay in memory',
    () async {
      final document = await composerDraftFile(portableData);
      await document.parent.create(recursive: true);
      await document.writeAsString('{not a draft document');

      final signals = ConversationPresentationSignals();
      addTearDown(signals.dispose);
      const store = PlatformComposerDraftStore();

      expect(
        await signals.loadComposerDrafts(
          store: store,
          portableData: portableData,
        ),
        isFalse,
      );

      signals.replaceComposerDraft('session:codex:one', 'kept in memory');
      await signals.flushComposerDrafts();

      expect(signals.composerDraftFor('session:codex:one'), 'kept in memory');
      expect(
        await document.readAsString(),
        '{not a draft document',
        reason: 'an unreadable document is never replaced by a fresh one',
      );
    },
  );

  test(
    'text typed while the document is read wins over the stored draft',
    () async {
      final store = _DelayedComposerDraftStore({'session:codex:one': 'stored'});
      final signals = ConversationPresentationSignals();
      addTearDown(signals.dispose);

      final loading = signals.loadComposerDrafts(
        store: store,
        portableData: portableData,
      );
      signals.replaceComposerDraft('session:codex:one', 'typed during load');
      store.releaseLoad();
      expect(await loading, isTrue);
      await signals.flushComposerDrafts();

      expect(
        signals.composerDraftFor('session:codex:one'),
        'typed during load',
      );
      expect(store.saved, [
        {'session:codex:one': 'typed during load'},
      ]);
    },
  );

  test('a keystroke burst coalesces into bounded document writes', () async {
    final store = _DelayedComposerDraftStore(const {});
    final signals = ConversationPresentationSignals();
    addTearDown(signals.dispose);
    store.releaseLoad();
    await signals.loadComposerDrafts(store: store, portableData: portableData);

    for (var index = 0; index < 200; index += 1) {
      signals.replaceComposerDraft('session:codex:one', 'draft $index');
    }
    await signals.flushComposerDrafts();

    expect(signals.composerDraftFor('session:codex:one'), 'draft 199');
    expect(store.saved.length, lessThan(200));
    expect(store.saved.last, {'session:codex:one': 'draft 199'});
  });

  test('a restored draft is announced to the composer projection', () async {
    final empty = ConversationPresentationSignals();
    addTearDown(empty.dispose);
    var emptyAnnouncements = 0;
    empty.structureChanges.listen((_) => emptyAnnouncements += 1);
    final emptyStore = _DelayedComposerDraftStore(const {})..releaseLoad();

    expect(
      await empty.loadComposerDrafts(
        store: emptyStore,
        portableData: portableData,
      ),
      isTrue,
    );
    expect(emptyAnnouncements, 0, reason: 'a fresh domain has nothing to show');

    final signals = ConversationPresentationSignals();
    addTearDown(signals.dispose);
    var announcements = 0;
    signals.structureChanges.listen((_) => announcements += 1);
    final store = _DelayedComposerDraftStore(const {
      'session:codex:one': 'restored',
    })..releaseLoad();

    expect(
      await signals.loadComposerDrafts(
        store: store,
        portableData: portableData,
      ),
      isTrue,
    );

    expect(signals.composerDraftFor('session:codex:one'), 'restored');
    expect(
      announcements,
      1,
      reason: 'the composer projection was computed before this restore',
    );
  });
}

/// A store whose read completes on demand, so a test can type into the
/// composer while the document is still being read.
final class _DelayedComposerDraftStore implements ComposerDraftStore {
  _DelayedComposerDraftStore(this.restored);

  final Map<String, String> restored;
  final Completer<void> _loadGate = Completer<void>();
  final List<Map<String, String>> saved = [];

  void releaseLoad() {
    if (!_loadGate.isCompleted) _loadGate.complete();
  }

  @override
  Future<Map<String, String>?> load(Object portableData) async {
    await _loadGate.future;
    return restored;
  }

  @override
  Future<void> save(Object portableData, Map<String, String> drafts) async {
    saved.add(Map<String, String>.from(drafts));
  }
}
