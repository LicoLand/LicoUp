import 'package:flutter/material.dart';

/// How the shared Agents workspace renders conversation navigation in its
/// sidebar region.
enum AgentsSidebarStyle {
  /// Hierarchical agent, project, and session tree.
  agentTree,

  /// Flat, recency-ordered conversation list across agents.
  flatRecencyList,
}

/// How conversation messages are laid out in the transcript region.
enum AgentsMessageStyle {
  /// Document-like transcript of full-width message blocks.
  documentTranscript,

  /// Chat-style participant flow grouped by author.
  participantFlow,
}

/// How structured process events are surfaced between messages.
enum AgentsProcessStyle {
  /// Expandable process cards.
  processCard,

  /// Single-line inline status rows.
  inlineStatus,
}

/// How the composer presents runtime settings.
enum AgentsComposerStyle {
  /// The composer carries the embedded runtime settings bar.
  withRuntimeBar,

  /// The composer renders the input row only.
  plain,
}

/// Layout-owned presentation strategy for the shared Agents business surface.
///
/// The strategy selects between presentation variants only. It never changes
/// business state, controller behavior, or data flow, and the console
/// strategy reproduces the pre-strategy rendering exactly.
final class AgentsPresentationStrategy {
  const AgentsPresentationStrategy._({
    required this.sidebarStyle,
    required this.messageStyle,
    required this.processStyle,
    required this.composerStyle,
  });

  /// The current console rendering across every branch point.
  const AgentsPresentationStrategy.console()
    : this._(
        sidebarStyle: AgentsSidebarStyle.agentTree,
        messageStyle: AgentsMessageStyle.documentTranscript,
        processStyle: AgentsProcessStyle.processCard,
        composerStyle: AgentsComposerStyle.withRuntimeBar,
      );

  /// The messaging rendering: flat recency list, participant flow, inline
  /// process status, and a plain composer.
  const AgentsPresentationStrategy.messaging()
    : this._(
        sidebarStyle: AgentsSidebarStyle.flatRecencyList,
        messageStyle: AgentsMessageStyle.participantFlow,
        processStyle: AgentsProcessStyle.inlineStatus,
        composerStyle: AgentsComposerStyle.plain,
      );

  final AgentsSidebarStyle sidebarStyle;
  final AgentsMessageStyle messageStyle;
  final AgentsProcessStyle processStyle;
  final AgentsComposerStyle composerStyle;

  @override
  bool operator ==(Object other) =>
      other is AgentsPresentationStrategy &&
      other.sidebarStyle == sidebarStyle &&
      other.messageStyle == messageStyle &&
      other.processStyle == processStyle &&
      other.composerStyle == composerStyle;

  @override
  int get hashCode =>
      Object.hash(sidebarStyle, messageStyle, processStyle, composerStyle);

  @override
  String toString() =>
      'AgentsPresentationStrategy('
      'sidebarStyle: ${sidebarStyle.name}, '
      'messageStyle: ${messageStyle.name}, '
      'processStyle: ${processStyle.name}, '
      'composerStyle: ${composerStyle.name})';
}

/// Makes the active layout's Agents presentation strategy available to the
/// shared conversation feature widgets without exposing a profile identity.
final class LayoutAgentsStrategyScope extends InheritedWidget {
  const LayoutAgentsStrategyScope({
    super.key,
    required this.strategy,
    required super.child,
  });

  final AgentsPresentationStrategy strategy;

  /// Returns the nearest strategy, or the console strategy when no scope is
  /// installed, so unscoped surfaces keep the current rendering.
  static AgentsPresentationStrategy maybeOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LayoutAgentsStrategyScope>();
    return scope?.strategy ?? const AgentsPresentationStrategy.console();
  }

  /// Returns the nearest strategy and fails closed when no scope is
  /// installed.
  static AgentsPresentationStrategy of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LayoutAgentsStrategyScope>();
    if (scope == null) {
      throw StateError('layout_agents_strategy_missing');
    }
    return scope.strategy;
  }

  @override
  bool updateShouldNotify(LayoutAgentsStrategyScope oldWidget) =>
      oldWidget.strategy != strategy;
}
