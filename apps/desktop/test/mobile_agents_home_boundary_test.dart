import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'lib/src/frontend/features/mobile_relay/ui';
  const entryPath = '$root/mobile_agents_home.dart';
  const scenarioPaths = <String>[
    entryPath,
    '$root/mobile_surface_gestures.dart',
    '$root/mobile_agent_list.dart',
    '$root/mobile_add_agent.dart',
    '$root/mobile_local_agent.dart',
  ];

  test('mobile agents entry stays a small orchestration surface', () {
    final entry = File(entryPath);
    expect(entry.existsSync(), isTrue);
    final source = entry.readAsStringSync();
    expect(source, contains('class MobileAgentsHome extends StatefulWidget'));
    expect(source, contains('class MobileAgentsHomeState'));
    expect(source, isNot(contains('class MobileAddAgentSheet')));
  });

  test(
    'each independently accepted mobile agent scenario has a source file',
    () {
      for (final path in scenarioPaths) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: path);
        final source = file.readAsStringSync();
        expect(
          RegExp(r'^\s*part(?:\s+of)?\s+', multiLine: true).hasMatch(source),
          isFalse,
          reason: path,
        );
      }
    },
  );

  test(
    'mobile agent scenario imports are acyclic and point away from entry',
    () {
      final byName = <String, String>{
        for (final path in scenarioPaths) _basename(path): path,
      };
      final graph = <String, Set<String>>{};
      final importPattern = RegExp(
        r"import 'package:licoup/src/frontend/features/mobile_relay/ui/"
        r"(mobile_[^']+\.dart)';",
      );

      for (final path in scenarioPaths) {
        final name = _basename(path);
        final source = File(path).readAsStringSync();
        graph[name] = {
          for (final match in importPattern.allMatches(source))
            if (byName.containsKey(match.group(1))) match.group(1)!,
        };
        if (name != 'mobile_agents_home.dart') {
          expect(
            graph[name],
            isNot(contains('mobile_agents_home.dart')),
            reason: '$name must not depend on the orchestration entry',
          );
        }
      }

      final visiting = <String>{};
      final visited = <String>{};
      void visit(String node) {
        expect(
          visiting.add(node),
          isTrue,
          reason: 'mobile agent import cycle reaches $node',
        );
        for (final dependency in graph[node] ?? const <String>{}) {
          if (!visited.contains(dependency)) {
            visit(dependency);
          }
        }
        visiting.remove(node);
        visited.add(node);
      }

      for (final node in graph.keys) {
        if (!visited.contains(node)) {
          visit(node);
        }
      }
    },
  );
}

String _basename(String path) => path.substring(path.lastIndexOf('/') + 1);
