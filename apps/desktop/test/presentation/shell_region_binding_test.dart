import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';

void main() {
  testWidgets('text, badge, order and draft changes touch one region each', (
    tester,
  ) async {
    final document = _FakeSource(const _Document(title: 't', body: 'b'));
    final counters = _FakeSource(const _Counters(unread: 0, running: 0));
    final order = _FakeSource(const <String>['a', 'b']);
    final draft = _FakeSource(const _Draft(text: '', revision: 1));
    final builds = <String, int>{'text': 0, 'badge': 0, 'order': 0, 'draft': 0};

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            ProjectionBuilder<_Document, String>(
              source: document,
              select: (value) => value.body,
              builder: (context, body) {
                builds['text'] = builds['text']! + 1;
                return Text('body:$body');
              },
            ),
            ProjectionBuilder<_Counters, int>(
              source: counters,
              select: (value) => value.unread,
              builder: (context, unread) {
                builds['badge'] = builds['badge']! + 1;
                return Text('badge:$unread');
              },
            ),
            ProjectionBuilder<List<String>, List<String>>(
              source: order,
              select: (value) => value,
              builder: (context, value) {
                builds['order'] = builds['order']! + 1;
                return Text('order:${value.join(',')}');
              },
            ),
            ProjectionBuilder<_Draft, String>(
              source: draft,
              select: (value) => value.text,
              builder: (context, text) {
                builds['draft'] = builds['draft']! + 1;
                return Text('draft:$text');
              },
            ),
          ],
        ),
      ),
    );

    expect(builds, <String, int>{
      'text': 1,
      'badge': 1,
      'order': 1,
      'draft': 1,
    });

    // A body-text change rebuilds the text region only.
    document.publish(const _Document(title: 't', body: 'b2'));
    await tester.pump();
    expect(find.text('body:b2'), findsOneWidget);
    expect(builds, <String, int>{
      'text': 2,
      'badge': 1,
      'order': 1,
      'draft': 1,
    });

    // A badge change rebuilds the badge region only.
    counters.publish(const _Counters(unread: 3, running: 0));
    await tester.pump();
    expect(find.text('badge:3'), findsOneWidget);
    expect(builds, <String, int>{
      'text': 2,
      'badge': 2,
      'order': 1,
      'draft': 1,
    });

    // A table-of-contents order change rebuilds the order region only.
    order.publish(const <String>['b', 'a']);
    await tester.pump();
    expect(find.text('order:b,a'), findsOneWidget);
    expect(builds, <String, int>{
      'text': 2,
      'badge': 2,
      'order': 2,
      'draft': 1,
    });

    // A draft change rebuilds the draft region only.
    draft.publish(const _Draft(text: 'hello', revision: 2));
    await tester.pump();
    expect(find.text('draft:hello'), findsOneWidget);
    expect(builds, <String, int>{
      'text': 2,
      'badge': 2,
      'order': 2,
      'draft': 2,
    });

    // An unrelated field of an observed projection is not a region change.
    counters.publish(const _Counters(unread: 3, running: 1));
    await tester.pump();
    expect(builds, <String, int>{
      'text': 2,
      'badge': 2,
      'order': 2,
      'draft': 2,
    });
  });

  testWidgets('an appearance region rebuilds without touching a page', (
    tester,
  ) async {
    final appearance = _FakeSource(const _Appearance(preset: 'light'));
    final document = _FakeSource(const _Document(title: 't', body: 'b'));
    var pageBuilds = 0;
    var appearanceBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            ProjectionBuilder<_Document, String>(
              source: document,
              select: (value) => value.body,
              builder: (context, body) {
                pageBuilds += 1;
                return Text('body:$body');
              },
            ),
            ProjectionBuilder<_Appearance, String>(
              source: appearance,
              select: (value) => value.preset,
              region: ShellRegionClass.appearance,
              builder: (context, preset) {
                appearanceBuilds += 1;
                return Text('theme:$preset');
              },
            ),
          ],
        ),
      ),
    );

    appearance.publish(const _Appearance(preset: 'dark'));
    await tester.pump();

    expect(find.text('theme:dark'), findsOneWidget);
    expect(appearanceBuilds, 2);
    expect(pageBuilds, 1);
  });

  testWidgets('A to B to A never mixes the region generation', (tester) async {
    final first = _FakeSource(1);
    final second = _FakeSource(2);
    var source = first;
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return ProjectionBuilder<int, int>(
              source: source,
              select: (value) => value,
              builder: (context, value) => Text('value:$value'),
            );
          },
        ),
      ),
    );
    expect(find.text('value:1'), findsOneWidget);

    rebuild(() => source = second);
    await tester.pump();
    expect(find.text('value:2'), findsOneWidget);
    expect(first.hasListener, isFalse);

    // The first source moves on while the region observes the second one.
    first.publish(7);
    await tester.pump();
    expect(find.text('value:2'), findsOneWidget);

    rebuild(() => source = first);
    await tester.pump();
    expect(find.text('value:7'), findsOneWidget);
    expect(second.hasListener, isFalse);
  });

  testWidgets('a background tab keeps its value and closes the gap on return', (
    tester,
  ) async {
    final document = _FakeSource(const _Document(title: 't', body: 'b'));
    var active = false;
    late StateSetter rebuild;
    var pageBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return ProjectionBuilder<_Document, String>(
              source: document,
              select: (value) => value.body,
              active: active,
              builder: (context, body) {
                pageBuilds += 1;
                return Text('body:$body');
              },
            );
          },
        ),
      ),
    );

    // The tab is not visible: it keeps its last committed value and does not
    // observe the source.
    expect(document.hasListener, isFalse);
    document.publish(const _Document(title: 't', body: 'b2'));
    await tester.pump();
    expect(find.text('body:b'), findsOneWidget);
    expect(pageBuilds, 1);

    rebuild(() => active = true);
    await tester.pump();

    // Returning to the tab reads the source again, so the gap opened while it
    // was away is closed without a stale generation being shown.
    expect(find.text('body:b2'), findsOneWidget);
    expect(pageBuilds, 2);
    expect(document.hasListener, isTrue);
  });
}

final class _Document {
  const _Document({required this.title, required this.body});

  final String title;
  final String body;
}

final class _Counters {
  const _Counters({required this.unread, required this.running});

  final int unread;
  final int running;
}

final class _Draft {
  const _Draft({required this.text, required this.revision});

  final String text;
  final int revision;
}

final class _Appearance {
  const _Appearance({required this.preset});

  final String preset;
}

final class _FakeSource<T> implements ProjectionSource<T> {
  _FakeSource(this._current);

  final StreamController<ProjectionUpdate<T>> _controller =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  T _current;

  bool get hasListener => _controller.hasListener;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _controller.stream;

  void publish(T value, {TraceContext? trace}) {
    _current = value;
    _controller.add(ProjectionUpdate<T>(value, trace: trace));
  }
}
