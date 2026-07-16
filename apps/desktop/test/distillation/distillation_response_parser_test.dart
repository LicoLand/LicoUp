import 'package:flutter_client/src/contracts/routing/distillation/distillation_response_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'fenced JSON is extracted and missing source metadata gets defaults',
    () {
      final package = parseDistillationPackageResponse(
        '''
prefix
```json
{"objective":" ship ","decisions":" use policy "}
```
suffix
''',
        sourceSessionId: 'source',
        sourceAgentId: 'agent',
        createdAt: 'now',
      );

      expect(package, isNotNull);
      expect(package?.objective, 'ship');
      expect(package?.decisions, ['use policy']);
      expect(package?.sourceSessionId, 'source');
      expect(package?.sourceAgentId, 'agent');
      expect(package?.createdAt, 'now');
    },
  );

  test(
    'explicit response metadata remains intact for caller normalization',
    () {
      final package = parseDistillationPackageResponse(
        'before {"objective":"ship","sourceSessionId":"response"} after',
        sourceSessionId: 'source',
        sourceAgentId: 'agent',
        createdAt: 'now',
      );

      expect(package?.sourceSessionId, 'response');
    },
  );

  test('empty, non-object, and malformed responses fail parsing', () {
    DistillationPackageParser call(String response) =>
        () => parseDistillationPackageResponse(
          response,
          sourceSessionId: 'source',
          sourceAgentId: 'agent',
          createdAt: 'now',
        );

    expect(call('')(), isNull);
    expect(call('[]')(), isNull);
    expect(call('{broken')(), isNull);
  });
}

typedef DistillationPackageParser = Object? Function();
