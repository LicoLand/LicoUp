import 'package:flutter/material.dart';
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

class _CounterNotifier extends Notifier<int> {
  @override
  int build() => 1;

  void increment() => state++;
}

final _counterProvider = NotifierProvider<_CounterNotifier, int>(
  _CounterNotifier.new,
);

void main() {
  test('Region is a thin ProviderListenable declaration', () {
    final provider = Provider<int>((ref) => 7);
    final region = _Region(provider);

    expect(region.source, same(provider));
    expect(region.actions, 'copy');
  });

  test('Region factory constructor constructs pure Region', () {
    final provider = Provider<String>((ref) => 'hello');
    final region = Region<String, int>(
      source: provider,
      actions: 42,
      render: (context, inputs, actions) => Text('$inputs-$actions'),
    );

    expect(region.source, same(provider));
    expect(region.actions, 42);
  });

  testWidgets('ConsumerRegion watches source and renders inputs with actions', (
    tester,
  ) async {
    final provider = Provider<String>((ref) => 'test-value');
    final region = Region<String, String>(
      source: provider,
      actions: 'test-action',
      render: (context, inputs, actions) => Text('$inputs | $actions'),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ConsumerRegion(region: region),
        ),
      ),
    );

    expect(find.text('test-value | test-action'), findsOneWidget);
  });

  testWidgets('ConsumerRegion.from creates widget directly from arguments', (
    tester,
  ) async {
    final provider = Provider<int>((ref) => 123);

    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ConsumerRegion<int, String>.from(
            source: provider,
            actions: 'act',
            render: (context, inputs, actions) =>
                Text('direct: $inputs-$actions'),
          ),
        ),
      ),
    );

    expect(find.text('direct: 123-act'), findsOneWidget);
  });

  testWidgets('Region.toWidget extension builds ConsumerRegion', (
    tester,
  ) async {
    final provider = Provider<String>((ref) => 'extension-test');
    final region = Region<String, void Function()>(
      source: provider,
      actions: () {},
      render: (context, inputs, actions) => Text(inputs),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: region.toWidget(),
        ),
      ),
    );

    expect(find.text('extension-test'), findsOneWidget);
  });

  testWidgets('ConsumerRegion re-renders reactively on source state change', (
    tester,
  ) async {
    var actionCalled = false;

    final region = Region<int, void Function()>(
      source: _counterProvider,
      actions: () => actionCalled = true,
      render: (context, inputs, actions) =>
          ElevatedButton(onPressed: actions, child: Text('Count: $inputs')),
    );

    late WidgetRef capturedRef;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              capturedRef = ref;
              return ConsumerRegion(region: region);
            },
          ),
        ),
      ),
    );

    expect(find.text('Count: 1'), findsOneWidget);

    // Trigger action
    await tester.tap(find.byType(ElevatedButton));
    expect(actionCalled, isTrue);

    // Update state
    capturedRef.read(_counterProvider.notifier).increment();
    await tester.pump();

    expect(find.text('Count: 2'), findsOneWidget);
  });
}
