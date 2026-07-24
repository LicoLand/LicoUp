import 'dart:io';

import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'lib/src/contracts/mobile_relay';
  const libraryNames = <String>[
    'mobile_relay_models.dart',
    'mobile_relay_gateway.dart',
    'mobile_relay_paired_device.dart',
    'mobile_relay_trust_presentation.dart',
    'mobile_relay_config.dart',
    'mobile_relay_command.dart',
  ];

  test('mobile relay model components are normal acyclic libraries', () {
    final graph = <String, Set<String>>{};
    final dependencyPattern = RegExp(
      r"(?:import|export) '"
      r"(?:package:licoup/src/contracts/mobile_relay/)?"
      r"(mobile_relay_[^']+\.dart)'",
    );

    for (final name in libraryNames) {
      final source = File('$root/$name').readAsStringSync();
      expect(
        RegExp(r'^\s*part(?:\s+of)?\s+', multiLine: true).hasMatch(source),
        isFalse,
        reason: name,
      );
      graph[name] = {
        for (final match in dependencyPattern.allMatches(source))
          if (libraryNames.contains(match.group(1))) match.group(1)!,
      };
      if (name != 'mobile_relay_models.dart') {
        expect(
          source,
          isNot(contains('mobile_relay_models.dart')),
          reason: '$name must not reverse-import the public barrel',
        );
      }
    }

    final visiting = <String>{};
    final visited = <String>{};
    void visit(String node) {
      expect(
        visiting.add(node),
        isTrue,
        reason: 'mobile relay model dependency cycle reaches $node',
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
  });

  test('public model barrel preserves the mobile relay contract surface', () {
    final config = MobileRelayConfig.defaults();
    final command = MobileRelayCommand.fromJson({
      'commandId': 'command-1',
      'type': 'agent.sync',
      'payload': const <String, dynamic>{},
      'status': 'queued',
      'createdAt': '2026-01-01T00:00:00Z',
    });
    final trust = MobileRelayTrustPresentation.fromJson({'verified': false});

    expect(config.defaultGatewayUrl, isEmpty);
    expect(command.commandId, 'command-1');
    expect(trust.blocksProtectedSend, isTrue);
    expect(
      canonicalMobileRelayGatewayOrigin('https://EXAMPLE.test:443/'),
      'https://example.test',
    );
  });
}
