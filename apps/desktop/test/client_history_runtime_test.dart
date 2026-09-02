import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/client_controller/history_runtime_scenarios.dart';

const _scenarioFingerprints = <String, List<String>>{
  'agent switching lands on the new conversation home': [
    'expect(controller.preparingNewConversation, isTrue)',
    "expect(controller.selectedConversationSession?.id, 'codex-old')",
    'expect(controller.selectedConversationSession, isNull)',
  ],
  'new conversation stays unselected across refresh and sends without session id':
      [
        'await controller.refreshConversationSessions',
        'expect(controller.selectedConversationSession, isNull)',
        'expect(service.lastRuntimeMessageRequest',
        "'binaryPath': '/synthetic/bin/codex'",
      ],
  'sendConversationMessage routes through runtime adapter without local append':
      [
        'expect(service.runtimeMessageCalls, 1)',
        'expect(service.conversationAppendCalls, 0)',
        "expect(controller.lastError, isEmpty)",
      ],
  'sendConversationMessage projects progressive reply and process events in the active conversation':
      [
        "containsAll(['Hello world', 'Hello world.'])",
        "isNot(contains('Hello'))",
        'lessThanOrEqualTo(8)',
        "isNot(contains('Hello worldworld'))",
        'contains(AgentConversationMessageKind.toolCall)',
        "expect(committedSession?.id, 'native-codex-turn-bound')",
        "expect(committedSession?.nativeSessionId, 'native-codex-turn-bound')",
        "contains('Show live progress')",
      ],
  'completed streamed reply remains visible until native history catches up': [
    "contains('Synthetic Claude reply')",
    "await controller.refreshConversationSessions('claude-code')",
    'expect(controller.selectedLiveConversationMessages, isEmpty)',
  ],
  'runtime update events project one in-place runtime-update card': [
    "endsWith('-runtime-update')",
    "anyElement(contains('下载中'))",
    "contains('2026.08.04-aaa8809')",
    "expect(card.role, 'event')",
    "expect(card.text, 'completed')",
    "'submitted,accepted,responding,completed'",
  ],
};

const _expectedGroups = <String, List<String>>{
  'history_runtime/session_selection_scenarios.dart': [
    'agent switching lands on the new conversation home',
    'new conversation stays unselected across refresh and sends without session id',
  ],
  'history_runtime/message_dispatch_scenarios.dart': [
    'sendConversationMessage routes through runtime adapter without local append',
  ],
  'history_runtime/streaming_projection_scenarios.dart': [
    'sendConversationMessage projects progressive reply and process events in the active conversation',
    'runtime update events project one in-place runtime-update card',
  ],
  'history_runtime/streaming_readback_scenarios.dart': [
    'completed streamed reply remains visible until native history catches up',
  ],
};

void main() {
  registerClientHistoryRuntimeScenarios();

  test(
    'history runtime scenarios are behavior-grouped without losing coverage',
    () {
      final packageRoot = _desktopPackageRoot();
      final fixtureRoot = Directory(
        '${packageRoot.path}/test/fixtures/client_controller',
      );
      final facade = File('${fixtureRoot.path}/history_runtime_scenarios.dart');
      final facadeSource = facade.readAsStringSync();
      final importMatches = RegExp(
        r"import '([^']+)'\s*;",
      ).allMatches(facadeSource).toList();
      final groupPaths = importMatches
          .map((match) => match.group(1)!)
          .where((path) => path.startsWith('history_runtime/'))
          .toList();

      expect(groupPaths.toSet(), _expectedGroups.keys.toSet());
      expect(
        importMatches.map((match) => match.group(1)),
        everyElement(startsWith('history_runtime/')),
        reason: 'the facade may import only behavior-group registrars',
      );

      final registrationCalls = RegExp(
        r'\b(registerClientHistoryRuntime[A-Z]\w*Scenarios)\(\)\s*;',
      ).allMatches(facadeSource).map((match) => match.group(1)!).toList();
      expect(registrationCalls, hasLength(groupPaths.length));
      expect(registrationCalls.toSet(), hasLength(registrationCalls.length));
      expect(
        _facadeResidue(facadeSource),
        isEmpty,
        reason: 'the facade must only import and invoke group registrars',
      );

      final groupSources = <String, String>{
        for (final path in groupPaths)
          path: File('${fixtureRoot.path}/$path').readAsStringSync(),
      };
      final declarationsByGroup = <String, List<_TestDeclaration>>{};
      for (final entry in groupSources.entries) {
        final source = entry.value;
        expect(source, contains(RegExp(r'void register\w+Scenarios\(\)')));
        final declarations = _testDeclarations(source);
        declarationsByGroup[entry.key] = declarations;
        expect(
          declarations.map((declaration) => declaration.title).toList(),
          unorderedEquals(_expectedGroups[entry.key]!),
          reason:
              '${entry.key} must own exactly its declared behavior scenarios',
        );
        expect(source, isNot(contains(RegExp(r'class\s+FakeAgentService\b'))));
        expect(
          source,
          isNot(
            contains(
              RegExp(r'Map<String,\s*dynamic>\s+conversationSessionJson\s*\('),
            ),
          ),
        );
      }
      for (final call in registrationCalls) {
        expect(
          groupSources.values.where(
            (source) => RegExp('void\\s+$call\\(\\)').hasMatch(source),
          ),
          hasLength(1),
          reason: '$call must have exactly one imported group owner',
        );
      }

      final allDeclarations = declarationsByGroup.values.expand(
        (value) => value,
      );
      for (final scenario in _scenarioFingerprints.entries) {
        final owners = allDeclarations.where(
          (declaration) => declaration.title == scenario.key,
        );
        expect(
          owners,
          hasLength(1),
          reason: "actual test '${scenario.key}' must be declared exactly once",
        );
        final body = _normalized(owners.single.body);
        for (final fingerprint in scenario.value) {
          expect(
            body,
            contains(_normalized(fingerprint)),
            reason: "test body '${scenario.key}' lost assertion '$fingerprint'",
          );
        }
      }

      final fixtureSources = fixtureRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => MapEntry(file.path, file.readAsStringSync()))
          .toList();
      expect(
        fixtureSources
            .where(
              (entry) =>
                  RegExp(r'class\s+FakeAgentService\b').hasMatch(entry.value),
            )
            .map((entry) => entry.key),
        [endsWith('/support/fake_agent_service.dart')],
      );
      expect(
        fixtureSources
            .where(
              (entry) => RegExp(
                r'Map<String,\s*dynamic>\s+conversationSessionJson\s*\(',
              ).hasMatch(entry.value),
            )
            .map((entry) => entry.key),
        [endsWith('/support/client_controller_scenario_json.dart')],
      );
    },
  );
}

Directory _desktopPackageRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File('${candidate.path}/pubspec.yaml').existsSync() &&
        Directory(
          '${candidate.path}/test/fixtures/client_controller',
        ).existsSync()) {
      return candidate;
    }
    final parent = candidate.parent;
    if (parent.path == candidate.path) {
      throw StateError('Could not locate the desktop Flutter package root.');
    }
    candidate = parent;
  }
}

String _facadeResidue(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '')
    .replaceAll(RegExp(r"import '[^']+'\s*;"), '')
    .replaceAll(
      RegExp(r'void\s+registerClientHistoryRuntimeScenarios\(\)\s*'),
      '',
    )
    .replaceAll(
      RegExp(r'\bregisterClientHistoryRuntime[A-Z]\w*Scenarios\(\)\s*;'),
      '',
    )
    .replaceAll(RegExp(r'[{}\s]'), '');

String _normalized(String source) =>
    source.replaceAll(RegExp(r'\s+'), ' ').trim();

final class _TestDeclaration {
  const _TestDeclaration(this.title, this.body);

  final String title;
  final String body;
}

List<_TestDeclaration> _testDeclarations(String source) {
  final code = _codeOnly(source);
  final declarations = <_TestDeclaration>[];
  var cursor = 0;
  while (cursor < code.length) {
    final name = code.startsWith('testWidgets', cursor)
        ? 'testWidgets'
        : code.startsWith('test', cursor)
        ? 'test'
        : null;
    if (name == null ||
        (cursor > 0 && _isIdentifier(code.codeUnitAt(cursor - 1))) ||
        (cursor + name.length < code.length &&
            _isIdentifier(code.codeUnitAt(cursor + name.length)))) {
      cursor++;
      continue;
    }
    var next = _skipWhitespace(code, cursor + name.length);
    if (next >= code.length || code[next] != '(') {
      cursor++;
      continue;
    }
    next = _skipWhitespace(code, next + 1);
    final title = _readString(source, next);
    if (title == null) {
      cursor++;
      continue;
    }
    next = _skipWhitespace(code, title.end);
    if (next >= code.length || code[next] != ',') {
      cursor++;
      continue;
    }
    final bodyOpen = _closureBodyOpen(code, next + 1);
    if (bodyOpen == null) {
      cursor++;
      continue;
    }
    final bodyClose = _matchingBrace(code, bodyOpen);
    declarations.add(
      _TestDeclaration(title.value, source.substring(bodyOpen + 1, bodyClose)),
    );
    cursor = bodyClose + 1;
  }
  return declarations;
}

({String value, int end})? _readString(String source, int start) {
  if (start >= source.length ||
      (source[start] != "'" && source[start] != '"')) {
    return null;
  }
  final quote = source[start];
  var cursor = start + 1;
  final value = StringBuffer();
  while (cursor < source.length) {
    if (source[cursor] == '\\' && cursor + 1 < source.length) {
      value.write(source[cursor + 1]);
      cursor += 2;
      continue;
    }
    if (source[cursor] == quote) {
      return (value: value.toString(), end: cursor + 1);
    }
    value.write(source[cursor]);
    cursor++;
  }
  return null;
}

int? _closureBodyOpen(String source, int start) {
  var cursor = _skipWhitespace(source, start);
  if (cursor + 1 >= source.length ||
      source.substring(cursor, cursor + 2) != '()') {
    return null;
  }
  cursor = _skipWhitespace(source, cursor + 2);
  if (source.startsWith('async', cursor)) {
    cursor = _skipWhitespace(source, cursor + 5);
  }
  return cursor < source.length && source[cursor] == '{' ? cursor : null;
}

int _matchingBrace(String source, int open) {
  var depth = 1;
  var cursor = open + 1;
  while (cursor < source.length) {
    if (source[cursor] == '{') depth++;
    if (source[cursor] == '}' && --depth == 0) return cursor;
    cursor++;
  }
  throw FormatException('Unclosed test body at offset $open');
}

int _skipWhitespace(String source, int start) {
  var cursor = start;
  while (cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
    cursor++;
  }
  return cursor;
}

String _codeOnly(String source) {
  final codeUnits = source.codeUnits.toList();
  var cursor = 0;
  void mask(int start, int end) {
    for (var index = start; index < end; index++) {
      codeUnits[index] = 32;
    }
  }

  while (cursor < source.length) {
    if (source.startsWith('//', cursor)) {
      final newline = source.indexOf('\n', cursor + 2);
      final end = newline < 0 ? source.length : newline;
      mask(cursor, end);
      cursor = end;
      continue;
    }
    if (source.startsWith('/*', cursor)) {
      final close = source.indexOf('*/', cursor + 2);
      if (close < 0) throw FormatException('Unclosed block comment');
      final end = close + 2;
      mask(cursor, end);
      cursor = end;
      continue;
    }
    if (source[cursor] == "'" || source[cursor] == '"') {
      final start = cursor;
      final quote = source[cursor];
      final tripleQuote = '$quote$quote$quote';
      final triple = source.startsWith(tripleQuote, cursor);
      final raw =
          cursor > 0 &&
          (source[cursor - 1] == 'r' || source[cursor - 1] == 'R') &&
          (cursor < 2 || !_isIdentifier(source.codeUnitAt(cursor - 2)));
      final terminator = triple ? tripleQuote : quote;
      cursor += terminator.length;
      var closed = false;
      while (cursor < source.length) {
        if (!raw && source[cursor] == '\\') {
          cursor += 2;
          continue;
        }
        if (source.startsWith(terminator, cursor)) {
          cursor += terminator.length;
          mask(start + terminator.length, cursor - terminator.length);
          closed = true;
          break;
        }
        cursor++;
      }
      if (!closed) {
        throw FormatException('Unclosed string at offset $start');
      }
      continue;
    }
    cursor++;
  }
  return String.fromCharCodes(codeUnits);
}

bool _isIdentifier(int codeUnit) =>
    (codeUnit >= 48 && codeUnit <= 57) ||
    (codeUnit >= 65 && codeUnit <= 90) ||
    (codeUnit >= 97 && codeUnit <= 122) ||
    codeUnit == 95 ||
    codeUnit == 36;
