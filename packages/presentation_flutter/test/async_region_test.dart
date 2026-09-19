import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

class _TestAsyncNotifier extends AsyncNotifier<String> {
  Completer<String>? _pending;
  String _current = '';
  bool _startLoading = true;

  @override
  Future<String> build() async {
    if (_startLoading && _pending == null) {
      final c = Completer<String>();
      _pending = c;
      return c.future;
    }
    final pending = _pending;
    if (pending != null) {
      return pending.future;
    }
    return _current;
  }

  void completeInitial(String val) {
    _current = val;
    final p = _pending;
    _pending = null;
    _startLoading = false;
    p?.complete(val);
  }

  void setData(String value) {
    _pending = null;
    _startLoading = false;
    _current = value;
    state = AsyncData<String>(value);
  }

  void startRefresh(Completer<String> completer) {
    _pending = completer;
    ref.invalidateSelf();
  }

  void setError(String message) {
    _pending = null;
    state = AsyncError<String>(message, StackTrace.empty);
  }
}

final _asyncStateProvider = AsyncNotifierProvider<_TestAsyncNotifier, String>(
  _TestAsyncNotifier.new,
);

void main() {
  testWidgets('AsyncRegion displays initial loading widget', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AsyncRegion<String, void Function()>(
            source: _asyncStateProvider,
            actions: () {},
            data: (context, data, actions) => Text('Data: $data'),
            loading: (context, actions) => const Text('Custom Loading...'),
          ),
        ),
      ),
    );

    expect(find.text('Custom Loading...'), findsOneWidget);
    expect(find.textContaining('Data:'), findsNothing);
  });

  testWidgets('AsyncRegion displays data when AsyncData arrives', (
    tester,
  ) async {
    late WidgetRef capturedRef;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              capturedRef = ref;
              return AsyncRegion<String, void Function()>(
                source: _asyncStateProvider,
                actions: () {},
                data: (context, data, actions) => Text('Data: $data'),
              );
            },
          ),
        ),
      ),
    );

    capturedRef
        .read(_asyncStateProvider.notifier)
        .completeInitial('hello-licoup');
    await tester.pump();

    expect(find.text('Data: hello-licoup'), findsOneWidget);
  });

  testWidgets('AsyncRegion displays error when AsyncError arrives', (
    tester,
  ) async {
    late WidgetRef capturedRef;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              capturedRef = ref;
              return AsyncRegion<String, void Function()>(
                source: _asyncStateProvider,
                actions: () {},
                data: (context, data, actions) => Text('Data: $data'),
                error: (context, error, stack, actions) =>
                    Text('Failed: $error'),
              );
            },
          ),
        ),
      ),
    );

    capturedRef
        .read(_asyncStateProvider.notifier)
        .setError('Network disconnected');
    await tester.pump();

    expect(find.text('Failed: Network disconnected'), findsOneWidget);
  });

  testWidgets(
    'AsyncRegion retains valid previous data during ordinary refresh',
    (tester) async {
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) {
                capturedRef = ref;
                return AsyncRegion<String, void Function()>(
                  source: _asyncStateProvider,
                  actions: () {},
                  retainPreviousDataOnRefresh: true,
                  data: (context, data, actions) => Text('Data: $data'),
                  loading: (context, actions) => const Text('Loading...'),
                );
              },
            ),
          ),
        ),
      );

      // Initial data
      capturedRef
          .read(_asyncStateProvider.notifier)
          .completeInitial('active-session');
      await tester.pump();
      expect(find.text('Data: active-session'), findsOneWidget);

      // Refresh begins: invalidate self with an uncompleted completer
      final refreshCompleter = Completer<String>();
      capturedRef
          .read(_asyncStateProvider.notifier)
          .startRefresh(refreshCompleter);
      await tester.pump();

      // Previous valid data is preserved across refresh frame
      expect(find.text('Data: active-session'), findsOneWidget);
      expect(find.text('Loading...'), findsNothing);

      // When refresh completes:
      refreshCompleter.complete('refreshed-session');
      await tester.pumpAndSettle();

      expect(find.text('Data: refreshed-session'), findsOneWidget);
    },
  );

  testWidgets(
    'Revocation guarantee: old frame is NOT retained when content is revoked',
    (tester) async {
      late WidgetRef capturedRef;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) {
                capturedRef = ref;
                return AsyncRegion<String, void Function()>(
                  source: _asyncStateProvider,
                  actions: () {},
                  retainPreviousDataOnRefresh: true,
                  // Mark session 'revoked-session' as revoked:
                  isRevoked: (data) => data.contains('revoked'),
                  revoked: (context, actions) => const Text('Access Revoked'),
                  data: (context, data, actions) => Text('Data: $data'),
                  loading: (context, actions) => const Text('Loading...'),
                );
              },
            ),
          ),
        ),
      );

      // 1. Initial valid data
      capturedRef
          .read(_asyncStateProvider.notifier)
          .completeInitial('valid-session');
      await tester.pump();
      expect(find.text('Data: valid-session'), findsOneWidget);

      // 2. Data changes to revoked
      capturedRef.read(_asyncStateProvider.notifier).setData('revoked-session');
      await tester.pump();

      // Must immediately show revoked view, not stale data
      expect(find.text('Access Revoked'), findsOneWidget);
      expect(find.textContaining('Data:'), findsNothing);

      // 3. During refresh with previous revoked value: must NOT retain old frame
      final refreshCompleter = Completer<String>();
      capturedRef
          .read(_asyncStateProvider.notifier)
          .startRefresh(refreshCompleter);
      await tester.pump();

      expect(find.text('Access Revoked'), findsOneWidget);
      expect(find.textContaining('Data:'), findsNothing);

      // 4. During error: must NOT retain old frame
      capturedRef.read(_asyncStateProvider.notifier).setError('Unauthorized');
      await tester.pump();

      expect(find.text('Access Revoked'), findsOneWidget);
      expect(find.textContaining('Data:'), findsNothing);
    },
  );
}
