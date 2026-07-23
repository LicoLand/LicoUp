import 'dart:math' as math;

/// One searchable conversation: title plus the bounded message text already
/// materialized for the session (preview or fully loaded messages).
class AgentConversationSearchDocument {
  const AgentConversationSearchDocument({
    required this.agentId,
    required this.sessionId,
    required this.title,
    required this.content,
    this.updatedAt,
  });

  final String agentId;
  final String sessionId;
  final String title;
  final String content;
  final DateTime? updatedAt;
}

class AgentConversationSearchHit {
  const AgentConversationSearchHit({
    required this.document,
    required this.score,
    required this.snippet,
    required this.titleMatched,
  });

  final AgentConversationSearchDocument document;
  final double score;
  final String snippet;
  final bool titleMatched;
}

/// Tokenizer for mixed CJK/Latin text: Latin letters and digits form word
/// tokens; CJK ideographs form overlapping bigrams (with unigram fallback for
/// isolated characters), the standard approach when no word segmentation is
/// available.
List<String> tokenizeAgentConversationSearchText(String text) {
  final tokens = <String>[];
  final word = StringBuffer();
  var pendingCjk = '';
  void flushWord() {
    if (word.isNotEmpty) {
      tokens.add(word.toString());
      word.clear();
    }
  }

  void flushCjk() {
    if (pendingCjk.isNotEmpty) {
      tokens.add(pendingCjk);
      pendingCjk = '';
    }
  }

  for (final rune in text.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    if (_isCjk(rune)) {
      flushWord();
      if (pendingCjk.isNotEmpty) {
        tokens.add('$pendingCjk$ch');
      }
      pendingCjk = ch;
    } else if (_isWordRune(rune)) {
      flushCjk();
      word.write(ch);
    } else {
      flushWord();
      flushCjk();
    }
  }
  flushWord();
  flushCjk();
  return tokens;
}

bool _isCjk(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0xF900 && rune <= 0xFAFF);

bool _isWordRune(int rune) =>
    (rune >= 0x61 && rune <= 0x7A) || // a-z (input is lowercased)
    (rune >= 0x30 && rune <= 0x39) || // 0-9
    rune == 0x2E || // .
    rune == 0x2D || // -
    rune == 0x5F; // _

class _DocEntry {
  _DocEntry(this.document, this.titleTokens, this.contentTokens);

  final AgentConversationSearchDocument document;
  final List<String> titleTokens;
  final List<String> contentTokens;
}

/// Inverted index over conversation titles and message content with a
/// BM25-inspired ranking: rarer terms weigh more (idf), title hits outweigh
/// content hits, term frequency saturates instead of dominating, exact phrase
/// substrings get a bonus, and fresher sessions get a bounded recency boost.
class AgentConversationSearchIndex {
  static const double _titleWeight = 4.0;
  static const double _contentWeight = 1.0;
  static const double _titlePhraseBonus = 8.0;
  static const double _contentPhraseBonus = 2.0;
  static const double _recencyBoost = 0.35;
  static const double _recencyHalfLifeDays = 21.0;

  final Map<String, _DocEntry> _documents = {};
  final Map<String, Map<String, int>> _titlePostings = {};
  final Map<String, Map<String, int>> _contentPostings = {};
  final Map<String, int> _documentFrequency = {};

  int get documentCount => _documents.length;

  void rebuild(Iterable<AgentConversationSearchDocument> documents) {
    _documents.clear();
    _titlePostings.clear();
    _contentPostings.clear();
    _documentFrequency.clear();
    for (final document in documents) {
      final key = '${document.agentId}\u001F${document.sessionId}';
      final titleTokens = tokenizeAgentConversationSearchText(document.title);
      final contentTokens = tokenizeAgentConversationSearchText(
        document.content,
      );
      _documents[key] = _DocEntry(document, titleTokens, contentTokens);
      final terms = <String>{...titleTokens, ...contentTokens};
      for (final term in terms) {
        _documentFrequency[term] = (_documentFrequency[term] ?? 0) + 1;
      }
      for (final term in titleTokens) {
        final postings = _titlePostings[term] ??= {};
        postings[key] = (postings[key] ?? 0) + 1;
      }
      for (final term in contentTokens) {
        final postings = _contentPostings[term] ??= {};
        postings[key] = (postings[key] ?? 0) + 1;
      }
    }
  }

  List<AgentConversationSearchHit> search(
    String query, {
    int limit = 50,
    DateTime? now,
  }) {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty || _documents.isEmpty) {
      return const [];
    }
    final terms = tokenizeAgentConversationSearchText(trimmed).toSet();
    final candidateKeys = <String>{};
    for (final term in terms) {
      candidateKeys.addAll(_titlePostings[term]?.keys ?? const Iterable<String>.empty());
      candidateKeys.addAll(_contentPostings[term]?.keys ?? const Iterable<String>.empty());
    }
    if (candidateKeys.isEmpty) {
      return const [];
    }
    final reference = now ?? DateTime.now();
    final hits = <AgentConversationSearchHit>[];
    for (final key in candidateKeys) {
      final entry = _documents[key]!;
      var score = 0.0;
      var matchedTerms = 0;
      for (final term in terms) {
        final titleTf = _titlePostings[term]?[key] ?? 0;
        final contentTf = _contentPostings[term]?[key] ?? 0;
        if (titleTf == 0 && contentTf == 0) {
          continue;
        }
        matchedTerms += 1;
        final idf = math.log(
          1 + _documents.length / ((_documentFrequency[term] ?? 0) + 1),
        );
        score += idf *
            (_titleWeight * _saturated(titleTf) +
                _contentWeight * _saturated(contentTf));
      }
      if (matchedTerms == 0) {
        continue;
      }
      // And-style coverage: documents matching more distinct query terms win.
      score *= matchedTerms / terms.length;
      final titleMatched = entry.document.title.toLowerCase().contains(
        trimmed,
      );
      if (titleMatched) {
        score += _titlePhraseBonus;
      } else if (entry.document.content.toLowerCase().contains(trimmed)) {
        score += _contentPhraseBonus;
      }
      final updatedAt = entry.document.updatedAt;
      if (updatedAt != null) {
        final ageDays = math.max(
          0,
          reference.difference(updatedAt).inHours / 24.0,
        );
        score *= 1 +
            _recencyBoost *
                math.pow(0.5, ageDays / _recencyHalfLifeDays);
      }
      hits.add(
        AgentConversationSearchHit(
          document: entry.document,
          score: score,
          snippet: _snippetFor(entry, terms, trimmed),
          titleMatched: titleMatched,
        ),
      );
    }
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) {
        return byScore;
      }
      final byFreshness = (b.document.updatedAt ?? DateTime(1970)).compareTo(
        a.document.updatedAt ?? DateTime(1970),
      );
      if (byFreshness != 0) {
        return byFreshness;
      }
      return a.document.title.compareTo(b.document.title);
    });
    return hits.take(limit).toList(growable: false);
  }

  double _saturated(int termFrequency) =>
      termFrequency / (termFrequency + 1.0);

  String _snippetFor(_DocEntry entry, Set<String> terms, String phrase) {
    final content = entry.document.content.replaceAll('\n', ' ').trim();
    if (content.isEmpty) {
      return '';
    }
    final lower = content.toLowerCase();
    var matchIndex = phrase.length >= 2 ? lower.indexOf(phrase) : -1;
    if (matchIndex < 0) {
      for (final term in terms) {
        matchIndex = lower.indexOf(term);
        if (matchIndex >= 0) {
          break;
        }
      }
    }
    if (matchIndex < 0) {
      return _clip(content, 0);
    }
    final start = math.max(0, matchIndex - 36);
    final prefix = start > 0 ? '…' : '';
    return '$prefix${_clip(content.substring(start), 96)}';
  }

  String _clip(String text, int maxChars) {
    final trimmed = text.trim();
    if (trimmed.length <= maxChars) {
      return trimmed;
    }
    return '${trimmed.substring(0, maxChars).trimRight()}…';
  }
}
