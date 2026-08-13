import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';

void main() {
  test('console strategy pins the current rendering styles', () {
    const strategy = AgentsPresentationStrategy.console();

    expect(strategy.sidebarStyle, AgentsSidebarStyle.agentTree);
    expect(strategy.messageStyle, AgentsMessageStyle.documentTranscript);
    expect(strategy.processStyle, AgentsProcessStyle.processCard);
    expect(strategy.composerStyle, AgentsComposerStyle.withRuntimeBar);
  });

  test('messaging strategy selects every messaging variant', () {
    const strategy = AgentsPresentationStrategy.messaging();

    expect(strategy.sidebarStyle, AgentsSidebarStyle.flatRecencyList);
    expect(strategy.messageStyle, AgentsMessageStyle.participantFlow);
    expect(strategy.processStyle, AgentsProcessStyle.inlineStatus);
    expect(strategy.composerStyle, AgentsComposerStyle.plain);
  });

  test('strategy equality, hash code, and label follow all four styles', () {
    const first = AgentsPresentationStrategy.console();
    const second = AgentsPresentationStrategy.console();
    const messaging = AgentsPresentationStrategy.messaging();

    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(first, isNot(messaging));
    expect(
      first.toString(),
      'AgentsPresentationStrategy('
      'sidebarStyle: agentTree, '
      'messageStyle: documentTranscript, '
      'processStyle: processCard, '
      'composerStyle: withRuntimeBar)',
    );
  });

  testWidgets('maybeOf falls back to the console strategy without a scope', (
    tester,
  ) async {
    AgentsPresentationStrategy? found;

    await tester.pumpWidget(
      Builder(
        builder: (context) {
          found = LayoutAgentsStrategyScope.maybeOf(context);
          return const SizedBox();
        },
      ),
    );

    expect(found, const AgentsPresentationStrategy.console());
  });

  testWidgets('of fails closed without a scope', (tester) async {
    Object? error;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          try {
            LayoutAgentsStrategyScope.of(context);
          } catch (value) {
            error = value;
          }
          return const SizedBox();
        },
      ),
    );

    expect(error, isA<StateError>());
    expect(error.toString(), contains('layout_agents_strategy_missing'));
  });

  testWidgets('scope overrides the fallback and notifies dependents', (
    tester,
  ) async {
    final seen = <AgentsPresentationStrategy>[];

    Widget build(AgentsPresentationStrategy strategy) {
      return LayoutAgentsStrategyScope(
        strategy: strategy,
        child: Builder(
          builder: (context) {
            seen.add(LayoutAgentsStrategyScope.maybeOf(context));
            return const SizedBox();
          },
        ),
      );
    }

    await tester.pumpWidget(build(const AgentsPresentationStrategy.console()));
    await tester.pumpWidget(
      build(const AgentsPresentationStrategy.messaging()),
    );

    expect(seen, [
      const AgentsPresentationStrategy.console(),
      const AgentsPresentationStrategy.messaging(),
    ]);
  });
}
