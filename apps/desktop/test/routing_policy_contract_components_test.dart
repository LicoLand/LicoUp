import 'dart:io';

import 'package:flutter_client/src/contracts/routing/routing_dispatch_failure.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_models.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_results.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart'
    show parseRoutingPolicyMap;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('model, result, parser, and dispatch contracts remain independent', () {
    const document = RoutingPolicyDocument(
      id: 'local-routing',
      agents: [RoutingPolicyAgent(id: 'codex')],
    );
    expect(document.identity, 'local-routing@2');
    expect(document.toJson()['agents'], hasLength(1));

    final parsed = parseRoutingPolicyMap(document.toJson());
    expect(parsed, isA<RoutingPolicyParseSuccess>());
    expect(
      const RoutingPolicyStoreLoaded(document).document.identity,
      document.identity,
    );

    final facts = RoutingDispatchFailureFacts.fromEnvelope(
      ok: false,
      errorCode: 'TEMPORARY',
      envelope: const {'transient': true, 'outcomeKnown': true},
    );
    expect(facts.errorCode, 'temporary');
    expect(facts.disposition, RoutingDispatchFailureDisposition.transientKnown);
  });

  test('routing policy barrel is bounded and has no duplicate contracts', () {
    const root = 'lib/src/contracts/routing';
    final barrel = File('$root/routing_policy_schema.dart').readAsStringSync();
    final components = [
      'routing_dispatch_failure.dart',
      'routing_policy_models.dart',
      'routing_policy_results.dart',
    ];
    expect(barrel.split('\n').length, lessThan(800));
    for (final component in components) {
      final source = File('$root/$component').readAsStringSync();
      expect(
        barrel,
        contains(
          "export 'package:flutter_client/src/contracts/routing/$component';",
        ),
      );
      expect(source.split('\n').length, lessThan(400));
      expect(source, isNot(contains('part of')));
    }
    expect(barrel, isNot(contains('class RoutingPolicyDocument')));
    expect(barrel, isNot(contains('class RoutingDispatchFailureFacts')));
    expect(barrel, isNot(contains('class RoutingPolicyValidationError')));
  });
}
