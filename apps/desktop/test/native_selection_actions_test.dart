import 'package:licoup/src/contracts/generated/client_error.g.dart';
import 'package:licoup/src/contracts/selection_policy.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_selection_actions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the matrix request names the generated method and the Agent', () async {
    final transport = _SelectionTransport()
      ..document = <String, dynamic>{
        'schemaVersion': 1,
        'scopes': <String>['direct', 'workflow'],
        'agent': 'codex',
      };
    final actions = NativeSelectionActions(stdioRpcTransport: transport);

    final document = await actions.matrixDocument('codex');
    expect(transport.methods, <String>['selection.matrix']);
    expect(transport.params.single, <String, dynamic>{'agent': 'codex'});
    // The document is handed on exactly as the owner rendered it: the
    // projection reads this contract, not a second copy of it.
    expect(document, transport.document);
    expect(
      identical(document, transport.document),
      isTrue,
      reason: 'the gateway must not rebuild the document it was given',
    );

    await actions.matrixDocument(
      'codex',
      params: <String, dynamic>{'env': 'work'},
    );
    expect(transport.params.last, <String, dynamic>{
      'agent': 'codex',
      'params': <String, dynamic>{'env': 'work'},
    });
  });

  test(
    'the policy read reports the owner binding, unadopted included',
    () async {
      final transport = _SelectionTransport()
        ..binding = const <String, dynamic>{'revisionName': 'unadopted'};
      final actions = NativeSelectionActions(stdioRpcTransport: transport);

      final binding = await actions.policy();
      expect(transport.methods, <String>['selection.policy.get']);
      expect(transport.params.single, isEmpty);
      expect(binding.hasRevisionInForce, isFalse);
      expect(binding.revisionName, selectionPolicyUnadoptedRevision);

      transport.binding = const <String, dynamic>{
        'revisionId': 'policy:r1',
        'revisionName': 'policy:r1',
        'preferences': <String, dynamic>{'preferredModel': 'model-a'},
      };
      final adopted = await actions.policy();
      expect(adopted.revisionId, 'policy:r1');
      expect(adopted.hasRevisionInForce, isTrue);
      expect(adopted.preferences.preferredModel, 'model-a');
    },
  );

  test('a transition sends exactly the revision the caller was given', () async {
    final transport = _SelectionTransport()
      ..binding = const <String, dynamic>{
        'revisionId': 'policy:r2',
        'revisionName': 'policy:r2',
      };
    final actions = NativeSelectionActions(stdioRpcTransport: transport);
    const revision = SelectionPolicyRevision(
      revisionId: 'policy:r2',
      parentRevisionId: 'policy:r1',
      provenance: 'feedback:outcome/policy:r2',
      preferences: SelectionPolicyPreferences(
        preferredModel: 'model-b',
        preferredSkills: <String>['skill-b'],
      ),
    );

    final superseded = await actions.supersede(revision);
    expect(transport.methods, <String>['selection.policy.supersede']);
    expect(transport.params.single, <String, dynamic>{
      'revision': <String, dynamic>{
        'revisionId': 'policy:r2',
        'parentRevisionId': 'policy:r1',
        'provenance': 'feedback:outcome/policy:r2',
        'preferences': <String, dynamic>{
          'preferredModel': 'model-b',
          'preferredSkills': <String>['skill-b'],
        },
      },
    });
    // The owner's answer is what the caller receives; the gateway adopts nothing
    // of its own.
    expect(superseded.revisionId, 'policy:r2');
  });

  test('a first adoption states no predecessor', () async {
    final transport = _SelectionTransport()
      ..binding = const <String, dynamic>{'revisionId': 'policy:r1'};
    final actions = NativeSelectionActions(stdioRpcTransport: transport);

    await actions.adopt(
      const SelectionPolicyRevision(
        revisionId: 'policy:r1',
        provenance: 'feedback:outcome/policy:r1',
      ),
    );
    expect(transport.methods, <String>['selection.policy.adopt']);
    final revision =
        transport.params.single['revision'] as Map<String, dynamic>;
    expect(revision.containsKey('parentRevisionId'), isFalse);
    expect(revision['preferences'], isEmpty);
  });

  test(
    'a revoke names the revision in force and refuses an empty one',
    () async {
      final transport = _SelectionTransport()
        ..binding = const <String, dynamic>{'revisionName': 'unadopted'};
      final actions = NativeSelectionActions(stdioRpcTransport: transport);

      await actions.revoke('policy:r2');
      expect(transport.methods, <String>['selection.policy.revoke']);
      expect(transport.params.single, <String, dynamic>{
        'revisionId': 'policy:r2',
      });

      await expectLater(
        actions.revoke('   '),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'invalid_params',
          ),
        ),
      );
      expect(transport.methods, <String>[
        'selection.policy.revoke',
      ], reason: 'a refused request must not reach the owner');
    },
  );

  test(
    'every refusal keeps the owner code through the generated contract',
    () async {
      for (final code in <String>[
        'selection_policy_already_adopted',
        'selection_policy_supersede_stale',
        'selection_policy_not_in_force',
        'selection_policy_predecessor_unknown',
        'selection_matrix_unavailable',
      ]) {
        final actions = NativeSelectionActions(
          stdioRpcTransport: _RefusingTransport(code),
        );
        try {
          await actions.policy();
          fail('a refusal must not read as an answer');
        } on LicoClientRpcException catch (error) {
          expect(selectionRefusalCode(error).wireName, code);
        }
      }
    },
  );

  test('a code the generated contract does not know stays unknown', () async {
    final actions = NativeSelectionActions(
      stdioRpcTransport: _RefusingTransport('selection_policy_something_new'),
    );
    try {
      await actions.policy();
      fail('an unknown refusal must not read as an answer');
    } on LicoClientRpcException catch (error) {
      expect(selectionRefusalCode(error), ClientErrorCode.unknown);
      expect(selectionRefusalCode(error).wireName, isEmpty);
    }
  });

  test(
    'an unreadable policy answer is refused, never read as unadopted',
    () async {
      // An answer that carries no policy document at all violates the result
      // contract of the method.
      for (final answer in <Object?>[null, 'not-a-document']) {
        final transport = _SelectionTransport()..binding = answer;
        final actions = NativeSelectionActions(stdioRpcTransport: transport);
        await expectLater(
          actions.policy(),
          throwsA(
            isA<LicoClientRpcException>().having(
              (error) => error.code,
              'code',
              'terminal_result_invalid',
            ),
          ),
          reason: 'answer $answer',
        );
      }

      // A policy document that states a revision this contract cannot read is
      // refused with the owner's own code for an unreadable register, because
      // "could not read" must not be reported as "nothing is adopted".
      for (final answer in <Object?>[
        <String, dynamic>{'revisionId': '   '},
        <String, dynamic>{'revisionId': 'revision:${'x' * 300}'},
        <String, dynamic>{'revisionId': 7},
      ]) {
        final transport = _SelectionTransport()..binding = answer;
        final actions = NativeSelectionActions(stdioRpcTransport: transport);
        await expectLater(
          actions.policy(),
          throwsA(
            isA<LicoClientRpcException>().having(
              (error) => error.code,
              'code',
              selectionPolicyUnavailableCode,
            ),
          ),
          reason: 'answer $answer',
        );
      }
    },
  );

  test('the revision contract refuses what the owner would refuse', () {
    expect(SelectionPolicyRevision.parse(null), isNull);
    expect(SelectionPolicyRevision.parse(const <String, dynamic>{}), isNull);
    expect(
      SelectionPolicyRevision.parse(const <String, dynamic>{'revisionId': 'r'}),
      isNull,
      reason: 'provenance is required by the owner too',
    );
    expect(
      SelectionPolicyRevision.parse(const <String, dynamic>{
        'revisionId': '',
        'provenance': 'p',
      }),
      isNull,
    );
    expect(
      SelectionPolicyRevision.parse(const <String, dynamic>{
        'revisionId': 'r',
        'provenance': 'p',
        'preferences': <String, dynamic>{
          'preferredModel': 'm',
          'preferredSkills': <String>['a', 'b'],
        },
      }),
      const SelectionPolicyRevision(
        revisionId: 'r',
        provenance: 'p',
        preferences: SelectionPolicyPreferences(
          preferredModel: 'm',
          preferredSkills: <String>['a', 'b'],
        ),
      ),
    );
  });
}

/// A transport that answers the selection methods from one canned binding.
final class _SelectionTransport implements NativeStdioRpcTransport {
  final List<String> methods = <String>[];
  final List<Map<String, dynamic>> params = <Map<String, dynamic>>[];
  Object? document = const <String, dynamic>{'schemaVersion': 1};
  Object? binding = const <String, dynamic>{'revisionName': 'unadopted'};

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> request,
  ) async {
    methods.add(method);
    params.add(request);
    return switch (method) {
      'selection.matrix' => <String, dynamic>{'matrix': document},
      _ => <String, dynamic>{'policy': binding},
    };
  }

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      throw UnsupportedError('raw selection CLI is not part of this contract');

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// A transport that refuses every request with one code.
final class _RefusingTransport implements NativeStdioRpcTransport {
  const _RefusingTransport(this.code);

  final String code;

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) => Future<Map<String, dynamic>>.error(LicoClientRpcException(code));

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      throw UnsupportedError('raw selection CLI is not part of this contract');

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) => const Stream.empty();

  @override
  Future<void> dispose() async {}
}
