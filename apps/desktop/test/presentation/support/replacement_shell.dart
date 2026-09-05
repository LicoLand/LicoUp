import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/environment/environment_projection_adapter.dart';
import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

/// A deliberately independent test renderer. It shares only immutable
/// presentation bindings with the production shell: no production layout
/// registry, destination widget, or theme resolver is reused.
final class ReplacementShell extends StatefulWidget {
  const ReplacementShell({
    super.key,
    required this.binding,
    required this.conversation,
    required this.onEffect,
    required this.onAgentsReset,
    required this.onDisposed,
  });

  final ShellBinding binding;
  final ConversationBinding conversation;
  final ValueChanged<ShellEffect> onEffect;
  final VoidCallback onAgentsReset;
  final VoidCallback onDisposed;

  @override
  State<ReplacementShell> createState() => _ReplacementShellState();
}

final class _ReplacementShellState extends State<ReplacementShell> {
  LayoutEnvironment? _scheduled;

  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => EffectListener<ShellEffect>(
    source: widget.binding.effects,
    onEffect: _handleEffect,
    child: ProjectionBuilder<AppearanceProjection, AppearanceProjection>(
      source: widget.binding.appearance,
      select: (value) => value,
      builder: (context, appearance) => LayoutBuilder(
        builder: (context, constraints) {
          final environmentProjection = widget.binding.environment.current;
          final measured = collectLayoutEnvironment(
            context,
            constraints,
            environmentProjection.runtimeSurface,
          );
          _scheduleEnvironmentUpdate(measured, environmentProjection);
          return ProjectionBuilder<LayoutProjection, LayoutProjection>(
            source: widget.binding.layout,
            select: (value) => value,
            builder: (context, layout) =>
                ProjectionBuilder<NavigationProjection, NavigationProjection>(
                  source: widget.binding.navigation,
                  select: (value) => value,
                  builder: (context, navigation) =>
                      ProjectionBuilder<ComposerProjection, ComposerProjection>(
                        source: widget.conversation.composer,
                        select: (value) => value,
                        builder: (context, composer) => KeyedSubtree(
                          key: Key(
                            'replacement-appearance-${appearance.presetId}',
                          ),
                          child: ColoredBox(
                            color: _replacementColor(appearance.presetId),
                            child: _buildLayout(
                              layout: layout,
                              navigation: navigation,
                              composer: composer,
                              measured: measured,
                            ),
                          ),
                        ),
                      ),
                ),
          );
        },
      ),
    ),
  );

  Widget _buildLayout({
    required LayoutProjection layout,
    required NavigationProjection navigation,
    required ComposerProjection composer,
    required LayoutEnvironment measured,
  }) {
    final profileId = layout.selection.effectiveId.value;
    final destination = _buildDestination(navigation.destination, composer);
    final navigationBar = Wrap(
      key: const Key('replacement-navigation'),
      children: [
        for (final section in navigation.destinations)
          TextButton(
            key: Key('replacement-nav-${section.name}'),
            onPressed: () =>
                widget.binding.intents.send(SelectShellDestination(section)),
            child: Text(section.name),
          ),
      ],
    );
    final shell = profileId == 'messaging'
        ? Column(
            children: [
              navigationBar,
              Expanded(child: destination),
            ],
          )
        : Row(
            children: [
              SizedBox(width: 120, child: navigationBar),
              Expanded(child: destination),
            ],
          );
    return Stack(
      key: Key('replacement-layout-$profileId'),
      children: [
        shell,
        IgnorePointer(
          child: Text(
            '${navigation.destination.name}:$profileId:'
            '${layout.selection.viewport.name}:'
            '${measured.width}:${measured.height}',
            key: const Key('replacement-shell-state'),
          ),
        ),
      ],
    );
  }

  Widget _buildDestination(
    ClientSection destination,
    ComposerProjection composer,
  ) => KeyedSubtree(
    key: const Key('replacement-destination'),
    child: destination == ClientSection.agents
        ? Text(
            '${composer.conversationId}:${composer.draft}',
            key: const Key('replacement-conversation'),
          )
        : Text(destination.name, key: Key('replacement-${destination.name}')),
  );

  void _scheduleEnvironmentUpdate(
    LayoutEnvironment measured,
    EnvironmentProjection current,
  ) {
    if (measured == current.environment || measured == _scheduled) return;
    _scheduled = measured;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduled != measured) return;
      _scheduled = null;
      widget.binding.intents.send(UpdateShellLayoutEnvironment(measured));
    });
  }

  void _handleEffect(ShellEffect effect) {
    widget.onEffect(effect);
    if (effect case ShellDestinationReselected(
      destination: ClientSection.agents,
    )) {
      widget.onAgentsReset();
    }
  }

  Color _replacementColor(String presetId) => presetId == 'lico-soda'
      ? const Color(0xff102030)
      : const Color(0xfff4f4f4);
}
