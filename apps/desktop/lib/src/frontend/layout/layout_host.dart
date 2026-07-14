import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/layout/layout_manager.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_selection.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:flutter_client/src/frontend/layout/layout_registry.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

final class LayoutHost extends StatefulWidget {
  const LayoutHost({
    super.key,
    required this.manager,
    required this.registry,
    required this.stateStore,
    required this.environment,
    required this.destination,
    required this.onSelectDestination,
    required this.content,
    required this.focusCoordinator,
    required this.availableFocusTargets,
    required this.primaryFocusTarget,
    required this.loadingBuilder,
  });

  final LayoutManager manager;
  final LayoutRegistry registry;
  final LayoutStateStore stateStore;
  final LayoutEnvironment environment;
  final ClientSection destination;
  final ValueChanged<ClientSection> onSelectDestination;
  final LayoutDestinationContentPort content;
  final LayoutFocusCoordinator focusCoordinator;
  final Set<String> availableFocusTargets;
  final String primaryFocusTarget;
  final WidgetBuilder loadingBuilder;

  @override
  State<LayoutHost> createState() => _LayoutHostState();
}

final class _LayoutHostState extends State<LayoutHost> {
  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_handleSelection);
  }

  @override
  void didUpdateWidget(LayoutHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager)) {
      oldWidget.manager.removeListener(_handleSelection);
      widget.manager.addListener(_handleSelection);
    }
    if (oldWidget.environment != widget.environment) {
      widget.manager.updateEnvironment(widget.environment);
    }
  }

  @override
  void dispose() {
    widget.manager.removeListener(_handleSelection);
    super.dispose();
  }

  void _handleSelection(LayoutSelectionState _) {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.manager.state;
    if (selection.status == LayoutSelectionStatus.loading) {
      return widget.loadingBuilder(context);
    }

    final key = LayoutVariantKey(
      profileId: selection.effectiveId,
      surface: widget.environment.surface,
      viewport: widget.environment.viewport,
    );
    final registered = widget.registry.variant(key);
    final destinationBuilder =
        registered.variant.destinationBuilders[widget.destination];
    if (destinationBuilder == null) {
      throw const FormatException('layout_host_destination_unregistered');
    }
    if (!identical(widget.stateStore.catalog, widget.registry.catalog)) {
      throw const FormatException('layout_host_catalog_mismatch');
    }

    final scopedState = LayoutScopedState(
      profileId: selection.effectiveId,
      surface: widget.environment.surface,
      store: widget.stateStore,
    );
    final destinations = registered.variant.destinationBuilders.keys.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final initialFocusTarget = widget.focusCoordinator.resolve(
      availableTargets: widget.availableFocusTargets,
      primaryTarget: widget.primaryFocusTarget,
    );
    final baseTheme = Theme.of(context);
    final extensions = [
      for (final extension in baseTheme.extensions.values)
        if (extension is! LayoutVisualTokens) extension,
      registered.bundle.tokens,
    ];
    return KeyedSubtree(
      key: ValueKey<String>('layout-host-${key.toString()}'),
      child: Theme(
        data: baseTheme.copyWith(extensions: extensions),
        child: LayoutScope(
          profileId: selection.effectiveId,
          environment: widget.environment,
          restorationNamespace: registered.bundle.restorationNamespace,
          tokens: registered.bundle.tokens,
          state: scopedState,
          child: Builder(
            builder: (profileContext) {
              final destination = destinationBuilder(
                profileContext,
                LayoutDestinationBuildContext(
                  environment: widget.environment,
                  destination: widget.destination,
                  content: widget.content,
                  state: scopedState,
                ),
              );
              return registered.variant.shellBuilder(
                profileContext,
                LayoutShellBuildContext(
                  environment: widget.environment,
                  activeDestination: widget.destination,
                  availableDestinations: destinations,
                  destination: destination,
                  onSelectDestination: widget.onSelectDestination,
                  components: registered.bundle.components,
                  tokens: registered.bundle.tokens,
                  initialFocusTarget: initialFocusTarget,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
