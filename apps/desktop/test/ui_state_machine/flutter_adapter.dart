import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/frontend/features/project_collaboration/ui/project_collaboration_strings.dart';

import 'model.dart';
import 'project_collaboration_harness.dart';

/// Only this adapter knows Flutter locators. The model never imports this file.
/// Actions always go through pointer gestures; observations inspect rendered UI.
final class FlutterInteractionAdapter {
  FlutterInteractionAdapter(
    this.tester,
    this.machine, {
    required this.nativeAgentId,
    this.collaboration,
  });
  final WidgetTester tester;
  final UiMachine machine;
  final String nativeAgentId;

  /// The project collaboration surface, when this machine drives it.
  final ProjectCollaborationHarness? collaboration;

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
    if (action == 'native.revoke' || action == 'native.reconnect') {
      // Native events the interface does not own; the harness drives them.
      return collaboration != null;
    }
    if (action == 'conversation.scroll-up' ||
        action == 'conversation.scroll-down') {
      return visible(key('canonical-group-conversation-pane'));
    }
    if (desktop && action.startsWith('settings.')) {
      // The Desktop settings surface has no index rail: section navigation is
      // a scroll inside the continuous content page.
      return visible(key('settings-content-scroll'));
    }
    if (collaboration != null &&
        (action.startsWith('project.') || action.startsWith('role.'))) {
      // Project and role controls live in an on-demand, independently
      // scrollable rail. The action is reachable while its real panel switch
      // is visible; act() opens the panel, scrolls, and uses the real control.
      return target(action).evaluate().isNotEmpty ||
          visible(key('project-collaboration-open-projects'));
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
      return key('messaging-sidebar-settings-${action.substring(9)}');
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
    const collaborationTargets = <String, String>{
      'project.select-build':
          'project-collaboration-node-licoup.node/alpha-build',
      'project.select-review':
          'project-collaboration-node-licoup.node/alpha-review',
      'project.collapse': 'project-collaboration-project-licoup.project/alpha',
      'project.expand': 'project-collaboration-project-licoup.project/alpha',
      'project.collapse-beta':
          'project-collaboration-project-licoup.project/beta',
      'project.expand-beta':
          'project-collaboration-project-licoup.project/beta',
      'detail.close': 'project-collaboration-detail-close',
      'view.list': 'project-collaboration-list-toggle',
      'view.lanes': 'project-collaboration-list-toggle',
      'view.inspector': 'project-collaboration-inspector-toggle',
      'view.inspector-close': 'project-collaboration-inspector-toggle',
      'zoom.in': 'project-collaboration-zoom-in',
      'zoom.reset': 'project-collaboration-zoom-reset',
      'insert.open': 'project-collaboration-insert',
      'insert.preview': 'project-collaboration-insert-preview',
      'insert.commit': 'project-collaboration-insert-commit',
      'insert.discard': 'project-collaboration-insert-commit-cancel',
      'insert.cancel': 'project-collaboration-insert-cancel',
      'confirm.cancel': 'project-collaboration-takeover-cancel',
      'confirm.takeover': 'project-collaboration-takeover-confirm-button',
      'confirm.pause': 'project-collaboration-takeover-confirm-button',
    };
    final mapped = collaborationTargets[action];
    if (mapped != null) return key(mapped);
    if (action == 'filter.frontier') {
      return key('project-collaboration-filter-frontier');
    }
    if (action == 'role.builder') {
      return key('project-collaboration-role-licoup.role/builder');
    }
    if (action == 'role.all') {
      return key('project-collaboration-role-all');
    }
    if (action == 'filter.anomalies') {
      return key('project-collaboration-filter-anomalies');
    }
    if (action == 'filter.all') {
      return key('project-collaboration-filter-all');
    }
    if (action == 'action.takeover') {
      return key('project-collaboration-action-licoup.action/unit-takeover');
    }
    if (action == 'action.pause') {
      return key('project-collaboration-action-licoup.action/unit-pause');
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
    if (action == 'native.revoke') {
      collaboration!.revoke();
      await tester.pump();
      return;
    }
    if (action == 'native.reconnect') {
      await collaboration!.reconnect();
      await tester.pump();
      return;
    }
    if (action == 'insert.preview') {
      // The unit reference is typed before the preview button is enabled; the
      // preview itself changes nothing.
      await tester.enterText(
        key('project-collaboration-insert-unit-ref'),
        'unit/alpha-extra',
      );
      await tester.pumpAndSettle();
      await tester.tap(target(action).hitTestable());
      await tester.pumpAndSettle();
      return;
    }
    if (action == 'insert.commit' ||
        action == 'confirm.takeover' ||
        action == 'confirm.pause') {
      await tester.tap(target(action).hitTestable());
      await tester.pumpAndSettle();
      // The receipt is a native answer: wait for it in real time.
      for (var frame = 0; frame < 60; frame++) {
        final receipt = collaboration?.session.lastReceipt;
        if (receipt != null) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pumpAndSettle();
      return;
    }
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
    if (desktop && action.startsWith('settings.')) {
      // Scroll the continuous settings page until the section content is on
      // screen. The page is a lazy ListView, so an off-screen heading may not
      // exist in the tree: the drag direction comes from the section order,
      // not from a possibly-unrendered target position.
      final section = action.substring(9);
      final heading = headings[section]!;
      final sectionIds = headings.keys.toList(growable: false);
      final targetIndex = sectionIds.indexOf(section);
      final content = key('settings-content-scroll');
      final targetFinder = find.descendant(
        of: content,
        matching: find.text(heading),
      );
      int firstVisibleSection() {
        for (var index = 0; index < sectionIds.length; index++) {
          if (visible(
            find.descendant(
              of: content,
              matching: find.text(headings[sectionIds[index]]!),
            ),
          )) {
            return index;
          }
        }
        return -1;
      }

      // Direction stabilizes on the last visible section heading; when none
      // is on screen the previous direction holds.
      var upward = targetIndex == 0;
      final scrollableFinder = find.descendant(
        of: content,
        matching: find.byType(Scrollable),
      );
      double? offsetOf() => scrollableFinder.evaluate().isEmpty
          ? null
          : tester
                .state<ScrollableState>(scrollableFinder.first)
                .position
                .pixels;
      for (var attempt = 0; attempt < 60; attempt++) {
        if (visible(targetFinder)) return;
        final anchor = firstVisibleSection();
        if (anchor >= 0) upward = targetIndex < anchor;
        await tester.timedDrag(
          content,
          Offset(0, upward ? 220 : -220),
          const Duration(milliseconds: 300),
        );
        await tester.pump(const Duration(milliseconds: 60));
        // Halt any residual fling so the next drag starts from rest;
        // otherwise momentum accumulates across drags and the scroll
        // overshoots the target section by viewports every attempt.
        if (offsetOf() case final current?) {
          tester
              .state<ScrollableState>(scrollableFinder.first)
              .position
              .jumpTo(current);
        }
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(
        visible(targetFinder),
        isTrue,
        reason: 'Settings section scrolled into view: $heading',
      );
      return;
    }
    if (collaboration != null &&
        (action.startsWith('project.') || action.startsWith('role.'))) {
      final finder = target(action);
      if (finder.evaluate().isEmpty) {
        await tester.tap(key('project-collaboration-open-projects'));
        await tester.pumpAndSettle();
      }
      expect(finder, findsOneWidget, reason: 'Reachable rail control: $action');
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      expect(
        finder.hitTestable(),
        findsOneWidget,
        reason: 'Visible rail control after scrolling: $action',
      );
      await tester.tap(finder.hitTestable());
      await tester.pumpAndSettle();
      final close = key('project-collaboration-close-projects');
      if (close.hitTestable().evaluate().isNotEmpty) {
        await tester.tap(close);
      }
      return;
    }
    final finder = target(action);
    // Feature projections can complete after the shell's first frames. A
    // setup click still goes through the real rendered control, but waits for
    // that control to join the tree before declaring the contract absent.
    for (
      var frame = 0;
      frame < 180 && finder.hitTestable().evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
      final error = tester.takeException();
      if (error != null) {
        throw TestFailure('UI exception while waiting for $action: $error');
      }
    }
    final candidates = finder.evaluate().toList();
    final geometry = candidates.isEmpty
        ? 'not built'
        : candidates
              .map(
                (element) => tester.getRect(
                  find.byElementPredicate((value) => identical(value, element)),
                ),
              )
              .join(', ');
    expect(
      finder.hitTestable(),
      findsOneWidget,
      reason: 'Visible clickable control: $action (geometry: $geometry)',
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
    if (collaboration != null) {
      return _atCollaboration(view ?? const <String, Object?>{});
    }
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

  /// Why the last project collaboration observation did not match.
  ///
  /// Reported with a failed wait so a real-engine run names the exact missing
  /// fact instead of only the state label.
  String? _lastCollaborationFailure;

  /// The project collaboration observation vocabulary.
  ///
  /// A state names the screen, dialog, detail, filter, receipt and zoom the
  /// surface must actually be showing; nothing is accepted as implied.
  bool _atCollaboration(Map<String, Object?> view) {
    final failed = <String>[];
    bool check(bool value, String label) {
      if (!value) failed.add(label);
      return value;
    }

    bool result(bool value, [String label = '']) {
      if (!value && label.isNotEmpty) failed.add(label);
      _lastCollaborationFailure = failed.isEmpty ? null : failed.join(', ');
      return value;
    }

    final observed = (view['project'] as Map?)?.cast<String, Object?>() ?? view;
    final dialog = observed['dialog'] as String?;
    final dialogs = <String, String>{
      'insert': 'project-collaboration-insert-dialog',
      'impact': 'project-collaboration-insert-impact',
      'confirm': 'project-collaboration-takeover-confirm',
    };
    if (dialog != null) {
      // A modal dialog covers the surface, so the page underneath is present
      // but no longer hit-testable; the dialog itself is the visible state.
      return result(
        key('project-collaboration-page').evaluate().isNotEmpty &&
            visible(key(dialogs[dialog]!)),
        'dialog:\$dialog',
      );
    }
    final unavailable = observed['unavailable'] == true;
    if (unavailable) {
      // A withdrawn authority leaves a calm placeholder, not an interactive
      // surface: it is present and named, and there is nothing to click.
      return result(
        key('project-collaboration-page').evaluate().isNotEmpty &&
            key('project-collaboration-unavailable').evaluate().isNotEmpty,
        'unavailable-visible',
      );
    }
    if (!check(visible(key('project-collaboration-page')), 'page')) {
      return result(false);
    }
    if (!check(
      key('project-collaboration-unavailable').evaluate().isEmpty,
      'no-unavailable',
    )) {
      return result(false);
    }
    if (!check(
      dialogs.values.every((value) => key(value).evaluate().isEmpty),
      'no-dialog',
    )) {
      return result(false);
    }
    if (observed['collapsed'] == true) {
      if (key(
        'project-collaboration-board-licoup.project/alpha',
      ).evaluate().isNotEmpty) {
        return false;
      }
      if (!visible(key('project-collaboration-summary-licoup.project/alpha'))) {
        return false;
      }
    }
    if (observed['screen'] == 'list') {
      if (!visible(key('project-collaboration-list'))) return false;
    } else {
      if (!visible(key('project-collaboration-graph'))) return false;
    }
    final detail = observed['detail'] as String?;
    if (observed['inspector'] == true) {
      // The advanced inspector replaces the node detail inside the same panel,
      // so the selected node is named by the inspector surface.
      if (detail == null) return false;
      if (!visible(key('project-collaboration-inspector-$detail'))) {
        return false;
      }
    } else if (detail != null) {
      if (!visible(key('project-collaboration-detail-$detail'))) return false;
    } else if (key('project-collaboration-detail').evaluate().isNotEmpty) {
      return false;
    }
    final role = observed['role'] as String?;
    if (role != null) {
      if (!visible(key('project-collaboration-node-licoup.node/alpha-build'))) {
        return false;
      }
      if (key(
        'project-collaboration-node-licoup.node/alpha-review',
      ).evaluate().isNotEmpty) {
        return false;
      }
    }
    final filter = observed['filter'] as String?;
    if (filter == 'frontier') {
      if (!visible(key('project-collaboration-node-licoup.node/alpha-build'))) {
        return false;
      }
      if (key(
        'project-collaboration-node-licoup.node/gamma-build',
      ).evaluate().isNotEmpty) {
        return false;
      }
    }
    if (filter == 'anomalies') {
      if (!visible(
        key('project-collaboration-node-licoup.node/alpha-review'),
      )) {
        return false;
      }
      if (key(
        'project-collaboration-node-licoup.node/alpha-build',
      ).evaluate().isNotEmpty) {
        return false;
      }
    }
    if (filter == 'all') {
      if (!visible(key('project-collaboration-node-licoup.node/alpha-build'))) {
        return false;
      }
    }
    final zoom = observed['zoom'];
    if (zoom != null && !visible(find.text('$zoom%'))) return false;
    final receipt = observed['receipt'] as String?;
    if (receipt != null) {
      final finder = find.byKey(
        const ValueKey<String>('project-collaboration-receipt'),
      );
      if (finder.evaluate().isEmpty) return false;
      final rendered = tester.widget<Text>(finder).data;
      // The line states the outcome in the interface language; the model names
      // the receipt code and the oracle accepts either language.
      final expected = <String>[
        graphViewStringsFor('zh').receipt(receipt),
        const GraphViewStrings().receipt(receipt),
      ];
      if (rendered == null ||
          !expected.any((message) => rendered.contains(message))) {
        return false;
      }
    }
    return true;
  }

  Future<void> waitFor(String state) async {
    // A bounded test assertion for a missing UI transition, never a timeout
    // applied to an application query, command, or persistent conversation.
    for (var frame = 0; frame < 180; frame += 1) {
      if (collaboration != null) {
        // The graph prepares in a real worker isolate, so the wait must let
        // real asynchronous work proceed between frames.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
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
    final missing = _lastCollaborationFailure == null
        ? ''
        : ' Missing: ${_lastCollaborationFailure!}.';
    throw TestFailure(
      'Expected visible state: ${machine.states[state]} (${machine.id}/$state).$detail$missing',
    );
  }
}
