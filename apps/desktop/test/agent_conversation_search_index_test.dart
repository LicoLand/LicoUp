import 'package:licoup/src/application/features/agents/conversation/agent_conversation_search_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tokenizer emits latin words and overlapping CJK bigrams', () {
    expect(
      tokenizeAgentConversationSearchText('GPT-5.5 发布新版本'),
      containsAll(<String>['gpt-5.5', '发布', '布新', '新版', '版本']),
    );
    expect(tokenizeAgentConversationSearchText('单'), ['单']);
    expect(tokenizeAgentConversationSearchText('hello world'), [
      'hello',
      'world',
    ]);
  });

  test('title hits outrank content-only hits', () {
    final index = _indexWith([
      _doc('a', 's1', title: 'Release pipeline', content: 'nothing here'),
      _doc(
        'a',
        's2',
        title: 'Unrelated',
        content: 'release release release notes',
      ),
    ]);

    final hits = index.search('release', now: _now);

    expect(hits.map((hit) => hit.document.sessionId).first, 's1');
    expect(hits.first.score, greaterThan(hits.last.score));
  });

  test('rare terms weigh more than frequent terms', () {
    final index = _indexWith([
      for (var i = 0; i < 10; i++)
        _doc('a', 'common-$i', title: 'common topic', content: ''),
      _doc('a', 'rare', title: 'common rare', content: ''),
    ]);

    final hits = index.search('rare common', now: _now);

    expect(hits.first.document.sessionId, 'rare');
  });

  test('phrase substring earns a bonus over scattered term hits', () {
    final index = _indexWith([
      _doc('a', 'phrase', title: 'fix the build', content: ''),
      _doc('a', 'scattered', title: 'fix', content: 'build'),
    ]);

    final hits = index.search('fix the build', now: _now);

    expect(hits.first.document.sessionId, 'phrase');
    expect(hits.first.titleMatched, isTrue);
  });

  test('fresher documents win on otherwise equal footing', () {
    final index = _indexWith([
      _doc('a', 'old', title: 'search me', content: '', daysAgo: 200),
      _doc('a', 'fresh', title: 'search me', content: '', daysAgo: 1),
    ]);

    final hits = index.search('search me', now: _now);

    expect(hits.first.document.sessionId, 'fresh');
  });

  test('snippet centers on the matched content term', () {
    final index = _indexWith([
      _doc(
        'a',
        's1',
        title: 'notes',
        content:
            'lots of unrelated text before the interesting needle appears here '
            'and more text follows afterwards for context',
      ),
    ]);

    final hits = index.search('needle', now: _now);

    expect(hits, hasLength(1));
    expect(hits.single.snippet, contains('needle'));
    expect(hits.single.snippet.startsWith('…'), isTrue);
  });

  test('CJK content matches through bigram tokens', () {
    final index = _indexWith([
      _doc('a', 's1', title: '随手记', content: '明天要发布新版本客户端'),
      _doc('a', 's2', title: '随手记', content: '无关内容'),
    ]);

    final hits = index.search('发布', now: _now);

    expect(hits.map((hit) => hit.document.sessionId), ['s1']);
  });

  test('empty query and unknown terms return nothing', () {
    final index = _indexWith([_doc('a', 's1', title: 'hello', content: '')]);
    expect(index.search('  ', now: _now), isEmpty);
    expect(index.search('zzz-unknown', now: _now), isEmpty);
  });
}

final DateTime _now = DateTime(2026, 7, 20, 12);

AgentConversationSearchDocument _doc(
  String agentId,
  String sessionId, {
  required String title,
  required String content,
  int daysAgo = 10,
}) {
  return AgentConversationSearchDocument(
    agentId: agentId,
    sessionId: sessionId,
    title: title,
    content: content,
    updatedAt: _now.subtract(Duration(days: daysAgo)),
  );
}

AgentConversationSearchIndex _indexWith(
  List<AgentConversationSearchDocument> docs,
) {
  return AgentConversationSearchIndex()..rebuild(docs);
}
