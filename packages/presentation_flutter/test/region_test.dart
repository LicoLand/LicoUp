import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

final class _Region implements Region<int, String> {
  _Region(this.source);

  @override
  final ProviderListenable<int> source;

  @override
  String get actions => 'copy';

  @override
  Widget Function(BuildContext, int, String) get render =>
      (context, inputs, actions) => Text('$inputs:$actions');
}

void main() {
  test('Region is a thin ProviderListenable declaration', () {
    final provider = Provider<int>((ref) => 7);
    final region = _Region(provider);

    expect(region.source, same(provider));
    expect(region.actions, 'copy');
  });
}
