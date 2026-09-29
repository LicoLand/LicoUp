import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';

void main() {
  final strings = LicoStrings.forLocale(const Locale('en'));

  test(
    'destination and copy failures state that the saved root is unchanged',
    () {
      final destination = strings.dataHomeOperationFailed(
        'move',
        'data_home_destination_exists',
      );
      final copy = strings.dataHomeOperationFailed(
        'move',
        'data_home_copy_failed',
      );

      expect(destination, contains('Choose another destination'));
      expect(destination, contains('was not changed'));
      expect(copy, contains('did not finish'));
      expect(copy, contains('original data remains'));
    },
  );

  test(
    'uncertain locator failure does not claim the previous root is active',
    () {
      final message = strings.dataHomeOperationFailed(
        'move',
        'data_home_relocation_recovery_required',
      );

      expect(message, contains('may already be active'));
      expect(message, contains('Check the current folder shown in Settings'));
      expect(message, isNot(contains('was not changed')));
    },
  );

  test('trash and marker failures report their distinct completed effects', () {
    final trashFailure = strings.dataHomeOperationFailed(
      'cleanup',
      'data_home_previous_root_cleanup_failed',
    );
    final markerFailure = strings.dataHomeOperationFailed(
      'cleanup',
      'data_home_previous_root_marker_cleanup_failed',
    );

    expect(trashFailure, contains('could not be moved to Trash'));
    expect(trashFailure, contains('original remains available'));
    expect(markerFailure, contains('was moved to Trash'));
    expect(markerFailure, contains('could not clear its saved cleanup record'));
  });
}
