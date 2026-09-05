import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation changes remain independently observable', () {
    final signals = ConversationPresentationSignals();
    addTearDown(signals.dispose);
    var structure = 0;
    var active = 0;
    var live = 0;
    var tabActivity = 0;
    signals.structureChanges.listen((_) => structure += 1);
    signals.activeChanges.listen((_) => active += 1);
    signals.liveChanges.listen((_) => live += 1);
    signals.tabActivityChanges.listen((_) => tabActivity += 1);

    signals.notifyStructureChanged(activeChanged: false);
    signals.notifyTabActivityChanged();
    expect(structure, 1);
    expect(active, 0);
    expect(live, 0);
    expect(tabActivity, 1);

    signals.notifyStructureChanged();
    signals.notifyActiveChanged();
    signals.notifyLiveChanged();
    expect(structure, 2);
    expect(active, 2);
    expect(live, 1);
    expect(tabActivity, 1);
  });

  test('composer drafts are scoped per conversation', () {
    final signals = ConversationPresentationSignals();
    addTearDown(signals.dispose);

    signals.replaceComposerDraft('session:codex:one', 'draft one');
    signals.replaceComposerDraft('session:codex:two', 'draft two');

    expect(signals.composerDraftFor('session:codex:one'), 'draft one');
    expect(signals.composerDraftFor('session:codex:two'), 'draft two');
    expect(signals.composerDraftFor('session:claude-code:one'), '');

    signals.replaceComposerDraft('session:codex:one', '');
    expect(signals.composerDraftFor('session:codex:one'), '');
    expect(signals.composerDraftFor('session:codex:two'), 'draft two');
  });
}
