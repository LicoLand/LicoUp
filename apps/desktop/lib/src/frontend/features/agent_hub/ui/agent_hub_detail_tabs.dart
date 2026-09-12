import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// One quiet track with a traveling selection, rather than independent chips.
class AgentHubDetailTabs extends StatelessWidget {
  const AgentHubDetailTabs({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final duration = context.motion(LicoMotion.medium);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: labels.length * 108),
        child: AgentHubDetailSelectorSurface(
          fill: colors.surfaceLow,
          stroke: colors.line,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final segmentWidth = constraints.maxWidth / labels.length;
                return Stack(
                  children: [
                    AnimatedPositionedDirectional(
                      duration: duration,
                      curve: LicoMotion.emphasized,
                      start: selectedIndex * segmentWidth,
                      top: 0,
                      bottom: 0,
                      width: segmentWidth,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surfaceRaised,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: colors.isDark ? 0.20 : 0.08,
                              ),
                              blurRadius: 5,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.arrowRight,
                        ): () =>
                            onSelected((selectedIndex + 1) % labels.length),
                        const SingleActivator(
                          LogicalKeyboardKey.arrowLeft,
                        ): () => onSelected(
                          (selectedIndex - 1 + labels.length) % labels.length,
                        ),
                        const SingleActivator(LogicalKeyboardKey.home): () =>
                            onSelected(0),
                        const SingleActivator(LogicalKeyboardKey.end): () =>
                            onSelected(labels.length - 1),
                      },
                      child: Row(
                        children: [
                          for (final (index, label) in labels.indexed)
                            Expanded(
                              child: Semantics(
                                selected: selectedIndex == index,
                                button: true,
                                child: InkWell(
                                  key: Key('agent-hub-detail-tab-$index'),
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () => onSelected(index),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 10,
                                    ),
                                    child: AnimatedDefaultTextStyle(
                                      duration: duration,
                                      curve: LicoMotion.standard,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge!
                                          .copyWith(
                                            color: selectedIndex == index
                                                ? colors.text
                                                : colors.textMuted,
                                            fontWeight: selectedIndex == index
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                      child: Text(
                                        label,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Stable page slots preserve each panel's scroll, search and loading state.
/// Selection crossfades content; hidden panels cannot accept input or tick.
class AgentHubDetailTabView extends StatelessWidget {
  const AgentHubDetailTabView({
    super.key,
    required this.selectedIndex,
    required this.children,
  });

  final int selectedIndex;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      for (final (index, child) in children.indexed)
        IgnorePointer(
          ignoring: index != selectedIndex,
          child: ExcludeFocus(
            excluding: index != selectedIndex,
            child: ExcludeSemantics(
              excluding: index != selectedIndex,
              child: AnimatedOpacity(
                duration: context.motion(LicoMotion.short),
                curve: LicoMotion.standard,
                opacity: index == selectedIndex ? 1 : 0,
                child: TickerMode(
                  enabled: index == selectedIndex,
                  child: child,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
