import 'dart:convert';

import 'package:flutter_client/src/contracts/routing/distillation/distillation_utf8.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UTF-8 truncation never splits a scalar or exceeds its byte budget', () {
    final value = truncateDistillationUtf8('你a好🙂', 4);
    expect(value, '你a');
    expect(utf8.encode(value).length, 4);
  });

  test('values already inside the budget are preserved verbatim', () {
    const value = 'routing';
    expect(truncateDistillationUtf8(value, 7), same(value));
  });
}
