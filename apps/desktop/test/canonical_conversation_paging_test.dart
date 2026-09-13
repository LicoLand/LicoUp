import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';

import 'support/canonical_group/paged_conversation_native.dart';

void main() {
  test(
    'latest and earlier pages use twenty real events across sequence gaps and sparse card anchors',
    () async {
      final native = PagedConversationNative(cardSequence: 2)
        ..events.remove(3)
        ..events.remove(7);
      final controller = await _selected(native);
      expect(native.pageRequests.first, containsPair('latest', true));
      expect(native.pageRequests.first['limit'], 20);
      expect(controller.events.map((event) => event.sequence), [
        2,
        ...List.generate(20, (i) => i + 46),
      ]);
      expect(controller.hasEarlierEvents, isTrue);
      for (final length in [41, 61, 63]) {
        await controller.loadEarlierEvents();
        expect(controller.events, hasLength(length));
      }
      expect(
        native.pageRequests
            .where((request) => request['beforeSequence'] != null)
            .map((request) => request['beforeSequence']),
        [46, 26, 5],
      );
      expect(
        native.pageRequests
            .where((request) => request['limit'] != 1)
            .map((request) => request['limit']),
        everyElement(20),
      );
      expect(
        controller.events.map((event) => event.sequence),
        native.events.keys,
      );
      expect(controller.hasEarlierEvents, isFalse);
      final reads = native.pageRequests.length;
      await controller.loadEarlierEvents();
      controller.clearSelection();
      await controller.selectConversation('group');
      expect(native.pageRequests, hasLength(reads));
      expect(controller.events, hasLength(63));
    },
  );

  test(
    'latest refresh fills bursts in twenty-event pages and retains the loaded history',
    () async {
      final native = PagedConversationNative();
      final controller = await _selected(native);
      await controller.loadEarlierEvents();
      native.appendThrough(112);
      expect(await controller.reloadSelected(), isTrue);
      expect(
        controller.events.map((event) => event.sequence),
        List.generate(87, (i) => i + 26),
      );
      expect(
        native.pageRequests.map((request) => request['limit']),
        everyElement(20),
      );
      expect(controller.events.map((event) => event.id).toSet(), hasLength(87));
      expect(controller.hasEarlierEvents, isTrue);
      await controller.loadEarlierEvents();
      expect(native.pageRequests.last['beforeSequence'], 26);
      expect(controller.events.first.sequence, 6);
    },
  );

  test(
    'older load deduplicates requests, retries failures and merges with a concurrent latest refresh',
    () async {
      final native = PagedConversationNative();
      final controller = await _selected(native);
      native.failEarlier = true;
      await controller.loadEarlierEvents();
      expect(controller.events, hasLength(20));
      expect(controller.earlierEventsError, isNotEmpty);
      native.failEarlier = false;
      native.earlierGate = Completer<void>();
      final older = controller.loadEarlierEvents();
      await controller.loadEarlierEvents();
      expect(controller.loadingEarlierEvents, isTrue);
      expect(controller.earlierEventsError, isEmpty);
      native.appendThrough(68);
      await controller.reloadSelected();
      native.earlierGate!.complete();
      await older;
      expect(
        controller.events.map((event) => event.sequence),
        List.generate(43, (i) => i + 26),
      );
      expect(
        native.pageRequests.where(
          (request) => request['beforeSequence'] != null,
        ),
        hasLength(2),
      );
      expect(controller.loadingEarlierEvents, isFalse);
    },
  );

  test(
    'late pages cannot replace a new selection or resurrect a cleared history',
    () async {
      final native = PagedConversationNative();
      final controller = await _selected(native);
      native.earlierGate = Completer<void>();
      final older = controller.loadEarlierEvents();
      await controller.selectConversation('other');
      native.earlierGate!.complete();
      await older;
      expect(controller.selectedConversationId, 'other');
      expect(controller.events, isEmpty);
      await controller.selectConversation('group');
      expect(controller.events, hasLength(40));
      native.earlierGate = Completer<void>();
      final beforeClear = controller.loadEarlierEvents();
      expect(await controller.clearSelectedHistory(), isTrue);
      native.earlierGate!.complete();
      await beforeClear;
      expect(controller.events, isEmpty);
      expect(controller.hasEarlierEvents, isFalse);
    },
  );

  test(
    'deleting a loaded older event preserves other loaded history without retaining the deleted event',
    () async {
      final native = PagedConversationNative();
      final controller = await _selected(native);
      await controller.loadEarlierEvents();
      expect(await controller.deleteMessage('event-28'), isTrue);
      expect(
        controller.events.map((event) => event.id),
        isNot(contains('event-28')),
      );
      expect(controller.events.first.sequence, 26);
      expect(controller.events, hasLength(39));
      expect(
        native.pageRequests.map((request) => request['limit']),
        everyElement(20),
      );
    },
  );

  test(
    'an earlier page completing during sparse task-card recovery stays retained',
    () async {
      final native = PagedConversationNative();
      final controller = await _selected(native);
      native.cardSequence = 2;
      native.anchorGate = Completer<void>();
      native.revision += 1;
      final latest = controller.reloadSelected();
      await Future<void>.delayed(Duration.zero);
      expect(native.pageRequests.last['limit'], 1);
      await controller.loadEarlierEvents();
      native.anchorGate!.complete();
      expect(await latest, isTrue);
      expect(controller.events.map((event) => event.sequence), [
        2,
        ...List.generate(40, (i) => i + 26),
      ]);
      await controller.loadEarlierEvents();
      expect(native.pageRequests.last['beforeSequence'], 26);
      expect(controller.events, hasLength(61));
    },
  );
}

Future<ClientConversationController> _selected(
  PagedConversationNative native,
) async {
  final controller = ClientConversationController(native: native);
  addTearDown(controller.dispose);
  await controller.initialize();
  await controller.selectConversation('group');
  return controller;
}
