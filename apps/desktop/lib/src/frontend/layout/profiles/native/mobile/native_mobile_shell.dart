import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/native_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/native_mobile_tokens.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

Widget buildNativeMobileCompactShell(
  BuildContext context,
  LayoutShellBuildContext data,
) {
  return _NativeCompactMobileShell(data: data);
}

Widget buildNativeMobileMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) {
  return _NativeMediumMobileShell(data: data);
}

final class _NativeCompactMobileShell extends StatefulWidget {
  const _NativeCompactMobileShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  State<_NativeCompactMobileShell> createState() =>
      _NativeCompactMobileShellState();
}

final class _NativeCompactMobileShellState
    extends State<_NativeCompactMobileShell>
    with RestorationMixin {
  final RestorableBool _navigationOpen = RestorableBool(false);

  @override
  String get restorationId => '$nativeMobileRestorationPrefix.compact-shell';

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
    final contentInsets = NativeMobileMetrics.safeContentInsets(environment);
    final motion = NativeMobileMetrics.motion(environment);
    final headerExtent = NativeMobileMetrics.compactHeaderExtentFor(
      environment.textScale,
    );

    final shell = Semantics(
      key: const Key('native-mobile-compact-shell'),
      container: true,
      label: nativeMobileStyleIdentity,
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
                        child: _NativeCompactHeader(
                          activeLabel: data.destinationLabel(
                            data.activeDestination,
                          ),
                          menuLabel: strings.features,
                          extent: headerExtent,
                          targetExtent: NativeMobileMetrics.targetExtent(
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
                                  'native-mobile-content-${data.initialFocusTarget}',
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
                          ? _NativeCompactNavigationOverlay(
                              key: const Key(
                                'native-mobile-navigation-overlay',
                              ),
                              data: data,
                              dismissLabel: strings.moreActions,
                              onDismiss: () => _setNavigationOpen(false),
                              onSelectDestination: _selectDestination,
                            )
                          : const SizedBox.shrink(
                              key: Key('native-mobile-navigation-closed'),
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
    return _withNativeMotionPolicy(
      context,
      reducedMotion: environment.reducedMotion,
      child: shell,
    );
  }
}

final class _NativeCompactHeader extends StatelessWidget {
  const _NativeCompactHeader({
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
      key: const Key('native-mobile-compact-header'),
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
                key: const Key('native-mobile-menu-button'),
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
                    NativeMobileMetrics.compactHeaderTextScaleCeiling,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'STUDIO',
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w800,
                        fontSize:
                            NativeMobileMetrics.compactHeaderEyebrowFontSize,
                        letterSpacing: 1.5,
                        height: 1,
                      ),
                    ),
                    const SizedBox(
                      height: NativeMobileMetrics.compactHeaderLineGap,
                    ),
                    Text(
                      activeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontSize:
                            NativeMobileMetrics.compactHeaderTitleFontSize,
                        fontWeight: FontWeight.w700,
                        height: NativeMobileMetrics.compactHeaderTitleHeight,
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

final class _NativeCompactNavigationOverlay extends StatelessWidget {
  const _NativeCompactNavigationOverlay({
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
          NativeMobileMetrics.compactDrawerMaxWidth,
          constraints.maxWidth * NativeMobileMetrics.compactDrawerWidthFactor,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            Semantics(
              button: true,
              label: dismissLabel,
              child: GestureDetector(
                key: const Key('native-mobile-overlay-barrier'),
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
                  key: const Key('native-mobile-contextual-drawer'),
                  child: Semantics(
                    container: true,
                    label: 'Native · ${LicoStrings.of(context).features}',
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight,
                        ),
                        child: ListView.separated(
                          key: const Key('native-mobile-compact-navigation'),
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
                                  'native-mobile-compact-navigation-${destination.name}',
                                ),
                                icon: Icon(
                                  nativeMobileDestinationIcon(destination),
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

final class _NativeMediumMobileShell extends StatelessWidget {
  const _NativeMediumMobileShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final environment = data.environment;
    final colors = context.layoutPalette;
    final contentInsets = NativeMobileMetrics.safeContentInsets(environment);

    final shell = Semantics(
      key: const Key('native-mobile-medium-shell'),
      container: true,
      label: nativeMobileStyleIdentity,
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
                  child: _NativeMediumNavigationRail(data: data),
                ),
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: KeyedSubtree(
                      key: ValueKey(
                        'native-mobile-medium-content-${data.initialFocusTarget}',
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
    return _withNativeMotionPolicy(
      context,
      reducedMotion: environment.reducedMotion,
      child: shell,
    );
  }
}

Widget _withNativeMotionPolicy(
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

final class _NativeMediumNavigationRail extends StatelessWidget {
  const _NativeMediumNavigationRail({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    return SizedBox(
      key: const Key('native-mobile-medium-rail'),
      width: NativeMobileMetrics.mediumRailExtent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(right: BorderSide(color: colors.line, width: 1)),
        ),
        child: Semantics(
          container: true,
          label: 'Native · ${strings.features}',
          child: Column(
            children: [
              const SizedBox(height: 8),
              RotatedBox(
                quarterTurns: 1,
                child: Text(
                  'STUDIO',
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
                  key: const Key('native-mobile-medium-navigation'),
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
                          'native-mobile-medium-navigation-${destination.name}',
                        ),
                        icon: Icon(nativeMobileDestinationIcon(destination)),
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
