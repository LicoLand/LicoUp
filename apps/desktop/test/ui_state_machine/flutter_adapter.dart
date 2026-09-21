import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model.dart';

/// Only this adapter knows Flutter locators. The model never imports this file.
/// Actions always go through pointer gestures; observations inspect rendered UI.
final class FlutterInteractionAdapter {
  FlutterInteractionAdapter(
    this.tester,
    this.machine, {
    required this.nativeAgentId,
  });
  final WidgetTester tester;
  final UiMachine machine;
  final String nativeAgentId;

  bool get desktop => machine.presentation.startsWith('desktop-');
  bool get wide => machine.presentation.endsWith('-wide');
  String get size => machine.presentation.split('-').last;

  static const sections = {
    'chats': 'agents',
    'agent-center': 'agentHub',
    'model-gateway': 'models',
    'device-pairing': 'mobileRelay',
    'usage': 'monitoring',
    'settings': 'settings',
  };
  static const apps = {
    'agent-center': 'agentHub',
    'model-gateway': 'modelsGateway',
    'device-pairing': 'mobileRelay',
    'usage': 'monitoring',
  };
  static const featureRows = {
    'agent-center': 'agentHub',
    'model-gateway': 'modelGateway',
    'device-pairing': 'mobilePairing',
    'usage': 'statsPanel',
  };
  static const headings = {
    'general': 'General',
    'appearance': 'Appearance',
    'updates': 'Client Update',
    'startup': 'Enable auto-start',
    'storage': 'Storage & Data',
    'diagnostics': 'Client Logs',
    'archived-conversations': 'Archived conversations',
  };

  Finder key(String value) => find.byKey(ValueKey<String>(value));
  bool visible(Finder finder) => finder.hitTestable().evaluate().isNotEmpty;

  Finder get listScroll => visible(key('messaging-contact-scroll'))
      ? key('messaging-contact-scroll')
      : key('agents-sidebar-conversation-scroll');

  bool available(String action) {
    if (action.endsWith('.dismiss') || action == 'nav.dismiss-menu') {
      return true;
    }
    if (action == 'conversation.scroll-up' ||
        action == 'conversation.scroll-down') {
      return visible(key('canonical-group-conversation-pane'));
    }
    if (action == 'list.refresh') return visible(listScroll);
    return visible(target(action));
  }

  Finder target(String action) {
    final simple = <String, String>{
      'search.type-settings': 'agent-conversation-search-field',
      'search.select-settings':
          'agent-conversation-search-feature:section-settings',
      'group.open': 'messaging-group-conversation-group',
      'list.back': 'messaging-conversation-list-back',
      'create.open': 'messaging-create-conversation',
      'roster.toggle': 'canonical-group-roster-toggle',
      'group.menu': 'canonical-group-menu-button',
      'group.actions': 'canonical-group-assistant-actions-trigger',
      'group.clear': 'canonical-group-action-archive',
      'pane.toggle': 'desktop-chrome-toggle',
    };
    if (action == 'search.clear') {
      return find.descendant(
        of: key('agent-conversation-search-field'),
        matching: find.byIcon(Icons.close_rounded),
      );
    }
    if (action == 'native.open') return key('messaging-contact-$nativeAgentId');
    if (simple.containsKey(action)) return key(simple[action]!);
    if (action == 'create.group') return find.text('New Group');
    if (action == 'dialog.cancel') return find.text('Cancel');
    if (action == 'search.open') return key('messaging-sidebar-search');
    if (action == 'nav.open-menu') {
      return key(
        desktop
            ? 'desktop-mobile-compact-navigation-trigger'
            : 'dashboard-mobile-menu-button',
      );
    }
    if (action.startsWith('settings.')) {
      final prefix = desktop
          ? 'settings-index-item-'
          : 'messaging-sidebar-settings-';
      return key('$prefix${action.substring(9)}');
    }
    if (action.startsWith('feature.')) {
      final feature = action.substring(8);
      return key(
        desktop
            ? 'desktop-launchpad-app-${apps[feature]}'
            : 'messaging-sidebar-list-${featureRows[feature]}',
      );
    }
    if (action.startsWith('dock.')) {
      return key('desktop-dock-entry-app:${apps[action.substring(5)]}');
    }
    if (action.startsWith('nav.')) {
      final name = action.substring(4);
      if (!wide) {
        final profile = desktop ? 'desktop' : 'dashboard';
        return key('$profile-mobile-$size-navigation-${sections[name]}');
      }
      if (desktop) {
        return key('desktop-dock-pin-$name');
      }
      return key(
        'messaging-sidebar-nav-${name == 'chats' ? 'conversations' : name}',
      );
    }
    throw StateError('No pointer mapping for $action');
  }

  /// Audit rendered, enabled controls as an independent inventory. Unknown
  /// controls remain visible in the report instead of disappearing from coverage.
  List<Map<String, Object?>> inventory(
    Iterable<String> actionIds,
    Set<String> outgoing,
  ) {
    final targets = <String, List<Rect>>{};
    for (final action in actionIds) {
      if (action.endsWith('.dismiss') ||
          action.contains('scroll-') ||
          action == 'list.refresh' ||
          action == 'nav.dismiss-menu') {
        continue;
      }
      try {
        targets[action] = [
          for (final element in target(action).hitTestable().evaluate())
            tester.getRect(
              find.byElementPredicate((value) => identical(value, element)),
            ),
        ];
      } on StateError {
        // Unmapped model actions are caught when their edge executes.
      }
    }
    final controls = <String, Map<String, Object?>>{};
    final candidates = find.byWidgetPredicate(
      (widget) => switch (widget) {
        InkResponse() =>
          widget.onTap != null ||
              widget.onDoubleTap != null ||
              widget.onSecondaryTap != null,
        GestureDetector() =>
          widget.onTap != null ||
              widget.onDoubleTap != null ||
              widget.onSecondaryTapDown != null,
        ButtonStyleButton() => widget.onPressed != null,
        IconButton() => widget.onPressed != null,
        _ => false,
      },
    );
    for (final element in candidates.hitTestable().evaluate()) {
      final finder = find.byElementPredicate(
        (value) => identical(value, element),
      );
      final rect = tester.getRect(finder);
      final matching = targets.entries
          .where(
            (entry) => entry.value.any(
              (box) =>
                  box.contains(rect.center) &&
                  box.width <= rect.width + 48 &&
                  box.height <= rect.height + 48,
            ),
          )
          .map((entry) => entry.key)
          .toList();
      final labels = find
          .descendant(of: finder, matching: find.byType(Text))
          .evaluate()
          .map((value) => (value.widget as Text).data ?? '')
          .where((value) => value.isNotEmpty)
          .toSet();
      var label = labels.take(3).join(' / ');
      element.visitAncestorElements((ancestor) {
        if (ancestor.widget case Tooltip(:final message?)) {
          if (label.isEmpty) label = message;
          return false;
        }
        return true;
      });
      if (label.isEmpty) label = 'Unlabelled clickable control';
      // Directory buttons can expose generated storage paths. Keep reports
      // useful without persisting machine-specific paths from the fixture.
      if (label.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(label)) {
        label = 'Directory selector';
      }
      final id = '${rect.left.round()}:${rect.top.round()}:$label';
      controls[id] = {
        'label': label,
        'actions': matching,
        'coveredHere': matching.any(outgoing.contains),
      };
    }
    return controls.values.toList();
  }

  Future<void> act(String action) async {
    if (action.endsWith('.dismiss') || action == 'nav.dismiss-menu') {
      if (!desktop && action == 'nav.dismiss-menu') {
        await tester.tap(key('dashboard-mobile-overlay-barrier'));
      } else {
        // Outside the visible dialog/menu, inside the application viewport.
        final size = tester.getSize(key('ui-interaction-root'));
        await tester.tapAt(Offset(size.width - 8, size.height - 8));
      }
      return;
    }
    if (action == 'search.type-settings') {
      await tester.enterText(
        key('agent-conversation-search-field'),
        'Settings',
      );
      return;
    }
    if (action == 'list.refresh') {
      await tester.timedDrag(
        listScroll,
        const Offset(0, 220),
        const Duration(milliseconds: 240),
      );
      return;
    }
    if (action == 'conversation.scroll-up' ||
        action == 'conversation.scroll-down') {
      final flow = find
          .descendant(
            of: key('canonical-group-conversation-pane'),
            matching: find.byType(Scrollable),
          )
          .first;
      final before = messagePositions(flow);
      final boundary = action.endsWith('up')
          ? 'Canonical message 1'
          : 'Canonical message 65';
      await tester.timedDrag(
        flow,
        Offset(0, action.endsWith('up') ? 350 : -350),
        const Duration(milliseconds: 240),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final after = messagePositions(flow);
      final moved = before.keys.any(
        (text) =>
            !after.containsKey(text) ||
            (before[text]! - after[text]!).distance > 1,
      );
      expect(before, isNotEmpty, reason: 'Scroll starts with visible messages');
      expect(
        moved || before.containsKey(boundary),
        isTrue,
        reason: 'Messages must move, or already be at the requested end',
      );
      return;
    }
    if (action == 'roster.toggle') {
      var finder = target(action);
      if (finder.hitTestable().evaluate().isEmpty) {
        // Desktop keeps the roster toggle inside the group menu.
        await tester.tap(key('canonical-group-menu-button'));
        await tester.pumpAndSettle();
        finder = target(action);
      }
      expect(
        finder.hitTestable(),
        findsOneWidget,
        reason: 'Visible clickable control: $action',
      );
      await tester.tap(finder.hitTestable());
      await tester.pumpAndSettle();
      return;
    }
    final finder = target(action);
    expect(
      finder.hitTestable(),
      findsOneWidget,
      reason: 'Visible clickable control: $action',
    );
    await tester.tap(finder.hitTestable());
  }

  Map<String, Offset> messagePositions(Finder flow) {
    final viewport = tester.getRect(flow);
    final result = <String, Offset>{};
    for (final element
        in find
            .descendant(of: flow, matching: find.byType(RichText))
            .evaluate()) {
      final text = (element.widget as RichText).text.toPlainText();
      if (!text.startsWith('Canonical message ')) continue;
      final rect = tester.getRect(
        find.byElementPredicate((candidate) => identical(candidate, element)),
      );
      if (viewport.contains(rect.center)) result[text] = rect.center;
    }
    return result;
  }

  bool at(String state) {
    final view = machine.observations[state];
    if (view != null) {
      if (view['destination'] != null) {
        return pageVisible(view['destination'] as String);
      }
      final overlay = view['overlay'] as String?;
      final overlays = {
        'search': 'agent-conversation-search-palette',
        'create': 'messaging-create-conversation-menu',
        'new-group': 'canonical-group-create-dialog',
        'group-actions': 'canonical-group-assistant-actions-menu',
        'group-menu': 'canonical-group-menu-panel',
        'clear-confirm': 'canonical-group-archive-confirm',
      };
      if (overlay != null) {
        if (!visible(
          key(
            overlay == 'search'
                ? 'agent-conversation-search-field'
                : overlays[overlay]!,
          ),
        )) {
          return false;
        }
        if (overlay == 'search') {
          return tester
                      .widget<TextField>(key('agent-conversation-search-field'))
                      .controller
                      ?.text ==
                  (view['query'] ?? '') &&
              (view['query'] == null ||
                  visible(target('search.select-settings')));
        }
        return true;
      }
      if (overlays.values.any((value) => key(value).evaluate().isNotEmpty)) {
        return false;
      }
      final list = view['list'] == 'group' || view['list'] == 'agent'
          ? 'messaging-conversation-list'
          : 'messaging-contact-list';
      if (!visible(key(list))) return false;
      if (view['page'] == 'native') {
        return visible(key('agent-conversation-composer-field')) &&
            key('canonical-group-conversation-pane').evaluate().isEmpty;
      }
      if (!visible(key('canonical-group-conversation-pane'))) return false;
      final roster = visible(key('canonical-group-roster'));
      return roster == view['roster'];
    }
    if (machine.id.endsWith('.settings')) {
      final content = key('settings-content-scroll');
      return visible(
        find.descendant(of: content, matching: find.text(headings[state]!)),
      );
    }
    if (machine.id.endsWith('.search')) {
      return state == 'search'
          ? visible(key('agent-conversation-search-field'))
          : key('agent-conversation-search-palette').evaluate().isEmpty &&
                pageVisible('chats');
    }
    if (machine.id.startsWith('desktop.window.')) {
      final feature = machine.id.substring('desktop.window.'.length);
      // The left pane keeps visited destinations mounted offstage, so assert
      // by hit-testable visibility, not by tree presence. The open app's dock
      // entry must be visible too: the strip's width animation clips a fresh
      // entry for a few frames after launch.
      return switch (state) {
        'features' => visible(key('desktop-launchpad')),
        'app' =>
          featureVisible(feature) &&
              visible(key('desktop-dock-entry-app:${apps[feature]}')),
        _ => false,
      };
    }
    if (machine.id == 'desktop.pane') {
      final viewportWidth = tester
          .getSize(key('desktop-left-pane-viewport'))
          .width;
      final listVisible =
          visible(key('messaging-conversation-list')) ||
          visible(key('messaging-contact-list'));
      return switch (state) {
        'open' => viewportWidth > 0 && !listVisible,
        'collapsed' => viewportWidth == 0 && listVisible,
        _ => false,
      };
    }
    if (state.endsWith('.menu')) {
      return visible(target('nav.chats')) &&
          visible(target('nav.settings')) &&
          visible(target('nav.device-pairing'));
    }
    if (!wide && size == 'compact' && visible(target('nav.settings'))) {
      return false;
    }
    return pageVisible(state);
  }

  bool featureVisible(String feature) => switch (feature) {
    'agent-center' => visible(
      find.descendant(of: key('agent-hub-panel'), matching: find.byType(Text)),
    ),
    'model-gateway' => visible(key('models-gateway-refresh')),
    'usage' => visible(key('agent-usage-refresh')),
    'device-pairing' => visible(find.text('Mobile Pairing')),
    _ => false,
  };

  bool pageVisible(String page) {
    if (wide) {
      if (page == 'settings') return visible(key('settings-content-scroll'));
      if (page == 'chats') {
        return visible(key('agent-conversation-composer-field')) ||
            (desktop && visible(key('desktop-dock-composer')));
      }
      if (desktop && page == 'features') {
        return visible(key('desktop-launchpad'));
      }
      return featureVisible(page);
    }
    final suffix = page == 'device-pairing' ? 'pairing' : sections[page]!;
    return visible(
      key(
        desktop
            ? 'desktop-mobile-$suffix-content'
            : 'dashboard-mobile-$suffix-destination',
      ),
    );
  }

  Future<void> waitFor(String state) async {
    // A bounded test assertion for a missing UI transition, never a timeout
    // applied to an application query, command, or persistent conversation.
    for (var frame = 0; frame < 180; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      final error = tester.takeException();
      if (error != null) {
        throw TestFailure('UI exception during ${machine.id} → $state: $error');
      }
      if (at(state)) return;
    }
    final search = key('agent-conversation-search-field');
    final detail = search.evaluate().isEmpty
        ? ''
        : ' Search text: ${tester.widget<TextField>(search).controller?.text}; Settings result exists: ${target('search.select-settings').evaluate().isNotEmpty}; clickable: ${visible(target('search.select-settings'))}.';
    throw TestFailure(
      'Expected visible state: ${machine.states[state]} (${machine.id}/$state).$detail',
    );
  }
}
