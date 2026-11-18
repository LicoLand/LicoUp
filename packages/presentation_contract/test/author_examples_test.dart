import 'package:test/test.dart';

import '../example/list_example.dart' as list;
import '../example/progress_example.dart' as progress;
import '../example/validated_input_example.dart' as input;

void main() {
  test('progress author example executes its contract checks', progress.main);
  test('list author example executes its contract checks', list.main);
  test('input author example executes its contract checks', input.main);
}
