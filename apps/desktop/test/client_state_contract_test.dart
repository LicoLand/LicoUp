import 'package:licoup/src/contracts/generated/client_state.g.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_state_actions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('typed state gateway uses structured get and set requests', () async {
    final transport = _StateTransport();
    final actions = NativeStateActions(stdioRpcTransport: transport);

    final get = await actions.get(ClientStateGetRequest(
      collection: ClientStateCollection.settings,
    ));
    expect(get.collection, ClientStateCollection.settings);
    expect(transport.methods, ['state.get']);

    final set = await actions.set(ClientStateSetRequest(
      collection: ClientStateCollection.settings,
      document: get.document,
    ));
    expect(set.collection, ClientStateCollection.settings);
    expect(set.activity.type, 'state.collection.saved');
    expect(transport.methods, ['state.get', 'state.set']);
  });

  test('generated decoder produces a bounded typed failure', () {
    final failure = ClientStateFailure.fromJson(const <String, Object?>{
      'code': 'invalid_collection',
    });
    expect(failure.code, ClientStateFailureCode.invalidCollection);
    expect(failure.toJson(), const <String, Object>{
      'code': 'invalid_collection',
    });
  });

  test('typed state gateway translates transport failures', () async {
    final actions = NativeStateActions(
      stdioRpcTransport: _FailingStateTransport(),
    );

    await expectLater(
      actions.get(ClientStateGetRequest(
        collection: ClientStateCollection.settings,
      )),
      throwsA(
        isA<ClientStateFailure>().having(
          (failure) => failure.code,
          'code',
          ClientStateFailureCode.invalidCollection,
        ),
      ),
    );
  });
}

class _StateTransport implements NativeStdioRpcTransport {
  final methods = <String>[];

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) async {
    methods.add(method);
    final collection = params['collection'];
    final document = <String, Object?>{
      'schemaVersion': 'v0.0.1:schema:definition-1',
      'collection': collection,
      'items': const <Object?>[],
    };
    if (method == 'state.get') {
      return <String, dynamic>{
        'ok': true,
        'collection': collection,
        'document': document,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'collection': collection,
      'document': document,
      'activity': <String, Object?>{
        'schemaVersion': 'v0.0.1:schema:definition-1',
        'eventId': 'activity-test',
        'type': 'state.collection.saved',
        'target': collection,
        'createdAt': 'test-time',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      throw UnsupportedError('raw state CLI is not part of this contract');

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

final class _FailingStateTransport extends _StateTransport {
  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) => Future<Map<String, dynamic>>.error(
    const LicoClientRpcException('invalid_collection'),
  );
}
