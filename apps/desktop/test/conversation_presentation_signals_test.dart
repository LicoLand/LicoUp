import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation revisions remain independently observable', () {
    final signals = ConversationPresentationSignals();
    addTearDown(signals.dispose);

    signals.notifyStructureChanged(activeChanged: false);
    expect(signals.structureListenable.value, 1);
    expect(signals.activeListenable.value, 0);

    signals.notifyStructureChanged();
    signals.notifyActiveChanged();
    signals.notifyLiveChanged();
    expect(signals.structureListenable.value, 2);
    expect(signals.activeListenable.value, 2);
    expect(signals.liveListenable.value, 1);
  });

  test('composer draft is independent from renderer lifecycle', () {
    final signals = ConversationPresentationSignals();
    addTearDown(signals.dispose);

    signals.replaceComposerDraft('draft');
    expect(signals.composerDraft, 'draft');
  });
}
