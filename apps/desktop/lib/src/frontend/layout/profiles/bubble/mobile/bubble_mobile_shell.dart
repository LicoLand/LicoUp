import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

Widget buildBubbleMobileCompactShell(
  BuildContext context,
  LayoutShellBuildContext data,
) {
  return _BubbleCompactMobileShell(data: data);
}

Widget buildBubbleMobileMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) {
  return _BubbleMediumMobileShell(data: data);
}

final class _BubbleCompactMobileShell extends StatefulWidget {
  const _BubbleCompactMobileShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  State<_BubbleCompactMobileShell> createState() =>
      _BubbleCompactMobileShellState();
}

final class _BubbleCompactMobileShellState
    extends State<_BubbleCompactMobileShell>
    with RestorationMixin {
  final RestorableBool _navigationOpen = RestorableBool(false);

  @override
  String get restorationId => '$bubbleMobileRestorationPrefix.compact-shell';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_navigationOpen, 'navigation-overlay');
  }

  @override
  void dispose() {
    _navigationOpen.dispose();
    super.dispose();
  }

  void _setNavigationOpen(bool value) {
    if (_navigationOpen.value == value) {
      return;
    }
    setState(() => _navigationOpen.value = value);
  }

  void _selectDestination(ClientSection destination) {
    widget.data.onSelectDestination(destination);
    _setNavigationOpen(false);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final environment = data.environment;
    final strings = LicoStrings.of(context);
    final colors = context.layoutPalette;
    final contentInsets = BubbleMobileMetrics.safeContentInsets(environment);
    final motion = BubbleMobileMetrics.motion(environment);
    final headerExtent = BubbleMobileMetrics.compactHeaderExtentFor(
      environment.textScale,
    );

    final shell = Semantics(
      key: const Key('bubble-mobile-compact-shell'),
      container: true,
      label: bubbleMobileStyleIdentity,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _setNavigationOpen(false),
        },
        child: Focus(
          skipTraversal: true,
          child: ColoredBox(
            color: colors.background,
            child: Padding(
              padding: contentInsets,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Column(
                    children: [
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: _BubbleCompactHeader(
                          activeLabel: data.destinationLabel(
                            data.activeDestination,
                          ),
                          menuLabel: strings.features,
                          extent: headerExtent,
                          targetExtent: BubbleMobileMetrics.targetExtent(
                            environment,
                          ),
                          open: _navigationOpen.value,
                          onPressed: () =>
                              _setNavigationOpen(!_navigationOpen.value),
                        ),
                      ),
                      Expanded(
                        child: FocusTraversalOrder(
                          order: const NumericFocusOrder(2),
                          child: ExcludeSemantics(
                            excluding: _navigationOpen.value,
                            child: IgnorePointer(
                              ignoring: _navigationOpen.value,
                              child: KeyedSubtree(
                                key: ValueKey(
                                  'bubble-mobile-content-${data.initialFocusTarget}',
                                ),
                                child: data.destination,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Positioned.fill(
                    top: headerExtent,
                    child: AnimatedSwitcher(
                      duration: motion,
                      reverseDuration: motion,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        final slide = Tween<Offset>(
                          begin: const Offset(-0.06, 0),
                          end: Offset.zero,
                        ).animate(animation);
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(position: slide, child: child),
                        );
                      },
                      child: _navigationOpen.value
                          ? _BubbleCompactNavigationOverlay(
                              key: const Key(
                                'bubble-mobile-navigation-overlay',
                              ),
                              data: data,
                              dismissLabel: strings.moreActions,
                              onDismiss: () => _setNavigationOpen(false),
                              onSelectDestination: _selectDestination,
                            )
                          : const SizedBox.shrink(
                              key: Key('bubble-mobile-navigation-closed'),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return _withBubbleMotionPolicy(
      context,
      reducedMotion: environment.reducedMotion,
      child: shell,
    );
  }
}

final class _BubbleCompactHeader extends StatelessWidget {
  const _BubbleCompactHeader({
    required this.activeLabel,
    required this.menuLabel,
    required this.extent,
    required this.targetExtent,
    required this.open,
    required this.onPressed,
  });

  final String activeLabel;
  final String menuLabel;
  final double extent;
  final double targetExtent;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return SizedBox(
      key: const Key('bubble-mobile-compact-header'),
      height: extent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(bottom: BorderSide(color: colors.line, width: 1)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: targetExtent,
              height: targetExtent,
              child: IconButton(
                key: const Key('bubble-mobile-menu-button'),
                tooltip: menuLabel,
                onPressed: onPressed,
                icon: AnimatedRotation(
                  turns: open ? 0.125 : 0,
                  duration:
                      MediaQuery.maybeOf(context)?.disableAnimations == true
                      ? Duration.zero
                      : const Duration(milliseconds: 120),
                  child: Icon(open ? Icons.close : Icons.grid_view_rounded),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor:
                    BubbleMobileMetrics.compactHeaderTextScaleCeiling,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'BUBBLE',
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w800,
                        fontSize:
                            BubbleMobileMetrics.compactHeaderEyebrowFontSize,
                        letterSpacing: 1.5,
                        height: 1,
                      ),
                    ),
                    const SizedBox(
                      height: BubbleMobileMetrics.compactHeaderLineGap,
                    ),
                    Text(
                      activeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontSize:
                            BubbleMobileMetrics.compactHeaderTitleFontSize,
                        fontWeight: FontWeight.w700,
                        height: BubbleMobileMetrics.compactHeaderTitleHeight,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

final class _BubbleCompactNavigationOverlay extends StatelessWidget {
  const _BubbleCompactNavigationOverlay({
    super.key,
    required this.data,
    required this.dismissLabel,
    required this.onDismiss,
    required this.onSelectDestination,
  });

  final LayoutShellBuildContext data;
  final String dismissLabel;
  final VoidCallback onDismiss;
  final ValueChanged<ClientSection> onSelectDestination;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          BubbleMobileMetrics.compactDrawerMaxWidth,
          constraints.maxWidth * BubbleMobileMetrics.compactDrawerWidthFactor,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            Semantics(
              button: true,
              label: dismissLabel,
              child: GestureDetector(
                key: const Key('bubble-mobile-overlay-barrier'),
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                child: ColoredBox(color: colors.background.withAlpha(184)),
              ),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: data.components.dialogSurface(
                  context,
                  key: const Key('bubble-mobile-contextual-drawer'),
                  child: Semantics(
                    container: true,
                    label: 'Bubble · ${LicoStrings.of(context).features}',
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight,
                        ),
                        child: ListView.separated(
                          key: const Key('bubble-mobile-compact-navigation'),
                          padding: const EdgeInsets.all(8),
                          shrinkWrap: true,
                          itemCount: data.availableDestinations.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 3),
                          itemBuilder: (context, index) {
                            final destination =
                                data.availableDestinations[index];
                            return FocusTraversalOrder(
                              order: NumericFocusOrder(index.toDouble()),
                              child: data.components.navigationItem(
                                context,
                                key: ValueKey(
                                  'bubble-mobile-compact-navigation-${destination.name}',
                                ),
                                icon: Icon(
                                  bubbleMobileDestinationIcon(destination),
                                ),
                                label: data.destinationLabel(destination),
                                selected: destination == data.activeDestination,
                                onPressed: () =>
                                    onSelectDestination(destination),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

final class _BubbleMediumMobileShell extends StatelessWidget {
  const _BubbleMediumMobileShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final environment = data.environment;
    final colors = context.layoutPalette;
    final contentInsets = BubbleMobileMetrics.safeContentInsets(environment);

    final shell = Semantics(
      key: const Key('bubble-mobile-medium-shell'),
      container: true,
      label: bubbleMobileStyleIdentity,
      child: ColoredBox(
        color: colors.background,
        child: Padding(
          padding: contentInsets,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FocusTraversalOrder(
                  order: const NumericFocusOrder(0),
                  child: _BubbleMediumNavigationRail(data: data),
                ),
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: KeyedSubtree(
                      key: ValueKey(
                        'bubble-mobile-medium-content-${data.initialFocusTarget}',
                      ),
                      child: data.destination,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return _withBubbleMotionPolicy(
      context,
      reducedMotion: environment.reducedMotion,
      child: shell,
    );
  }
}

Widget _withBubbleMotionPolicy(
  BuildContext context, {
  required bool reducedMotion,
  required Widget child,
}) {
  final mediaQuery = MediaQuery.maybeOf(context);
  if (mediaQuery == null || (!reducedMotion && !mediaQuery.disableAnimations)) {
    return child;
  }
  return MediaQuery(
    data: mediaQuery.copyWith(disableAnimations: true),
    child: child,
  );
}

final class _BubbleMediumNavigationRail extends StatelessWidget {
  const _BubbleMediumNavigationRail({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    return SizedBox(
      key: const Key('bubble-mobile-medium-rail'),
      width: BubbleMobileMetrics.mediumRailExtent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(right: BorderSide(color: colors.line, width: 1)),
        ),
        child: Semantics(
          container: true,
          label: 'Bubble · ${strings.features}',
          child: Column(
            children: [
              const SizedBox(height: 8),
              RotatedBox(
                quarterTurns: 1,
                child: Text(
                  'BUBBLE',
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.primary,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView.separated(
                  key: const Key('bubble-mobile-medium-navigation'),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  itemCount: data.availableDestinations.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 3),
                  itemBuilder: (context, index) {
                    final destination = data.availableDestinations[index];
                    return FocusTraversalOrder(
                      order: NumericFocusOrder(index.toDouble()),
                      child: data.components.navigationItem(
                        context,
                        key: ValueKey(
                          'bubble-mobile-medium-navigation-${destination.name}',
                        ),
                        icon: Icon(bubbleMobileDestinationIcon(destination)),
                        label: data.destinationLabel(destination),
                        selected: destination == data.activeDestination,
                        onPressed: () => data.onSelectDestination(destination),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 5),
            ],
          ),
        ),
      ),
    );
  }
}
