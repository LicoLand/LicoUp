import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/layout_variant.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

final class LayoutHost extends StatefulWidget {
  const LayoutHost({
    super.key,
    required this.selection,
    required this.registry,
    required this.stateStore,
    required this.environment,
    required this.onUpdateEnvironment,
    required this.destination,
    required this.onSelectDestination,
    required this.destinationLabel,
    required this.content,
    required this.focusCoordinator,
    required this.primaryFocusTarget,
    required this.loadingBuilder,
    required this.palette,
    required this.chrome,
  });

  final LayoutSelectionState selection;
  final LayoutRegistry registry;
  final LayoutStateStore stateStore;
  final LayoutEnvironment environment;
  final ValueChanged<LayoutEnvironment> onUpdateEnvironment;
  final ClientSection destination;
  final ValueChanged<ClientSection> onSelectDestination;
  final LayoutDestinationLabelResolver destinationLabel;
  final LayoutDestinationContentPort content;
  final LayoutFocusCoordinator focusCoordinator;
  final String primaryFocusTarget;
  final WidgetBuilder loadingBuilder;
  final LayoutPalette palette;
  final LayoutChromePort chrome;

  @override
  State<LayoutHost> createState() => _LayoutHostState();
}

final class _LayoutHostState extends State<LayoutHost> {
  LayoutVariantKey? _renderedKey;
  bool _restoreFocusAfterBuild = false;
  bool _focusRestoreScheduled = false;

  @override
  void initState() {
    super.initState();
    _validateCatalogIdentity();
    widget.onUpdateEnvironment(widget.environment);
    _renderedKey = _keyFor(widget.selection);
  }

  @override
  void didUpdateWidget(LayoutHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _validateCatalogIdentity();
    if (oldWidget.environment != widget.environment) {
      widget.onUpdateEnvironment(widget.environment);
    }
    if (oldWidget.selection != widget.selection) {
      _prepareReplacement(
        _keyFor(widget.selection),
        captureCoordinator:
            identical(oldWidget.focusCoordinator, widget.focusCoordinator)
            ? null
            : oldWidget.focusCoordinator,
      );
    }
  }

  LayoutVariantKey? _keyFor(LayoutSelectionState state) =>
      state.status == LayoutSelectionStatus.loading
      ? null
      : LayoutVariantKey(
          profileId: state.effectiveId,
          surface: state.surface,
          viewport: state.viewport,
        );

  void _prepareReplacement(
    LayoutVariantKey? nextKey, {
    LayoutFocusCoordinator? captureCoordinator,
  }) {
    if (_renderedKey == nextKey) {
      return;
    }
    if (_renderedKey != null) {
      final source = captureCoordinator ?? widget.focusCoordinator;
      final captured = source.captureActiveTarget();
      if (!identical(source, widget.focusCoordinator)) {
        widget.focusCoordinator.adoptCapturedTarget(captured);
      }
      _restoreFocusAfterBuild = true;
    }
    _renderedKey = nextKey;
  }

  void _scheduleFocusRestore() {
    if (!_restoreFocusAfterBuild || _focusRestoreScheduled) {
      return;
    }
    _focusRestoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusRestoreScheduled = false;
      if (!mounted || !_restoreFocusAfterBuild) {
        return;
      }
      _restoreFocusAfterBuild = false;
      widget.focusCoordinator.restore(primaryTarget: widget.primaryFocusTarget);
    });
  }

  void _validateCatalogIdentity() {
    if (!identical(widget.stateStore.catalog, widget.registry.catalog)) {
      throw const FormatException('layout_host_catalog_mismatch');
    }
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    if (selection.status == LayoutSelectionStatus.loading) {
      return widget.loadingBuilder(context);
    }

    final key = _keyFor(selection)!;
    _renderedKey = key;
    final registered = widget.registry.variant(key);
    final destinationBuilder =
        registered.variant.destinationBuilders[widget.destination];
    if (destinationBuilder == null) {
      throw const FormatException('layout_host_destination_unregistered');
    }
    final scopedState = LayoutScopedState(
      profileId: selection.effectiveId,
      surface: widget.environment.surface,
      destination: widget.destination,
      store: widget.stateStore,
    );
    final destinations = registered.variant.destinationBuilders.keys.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final initialFocusTarget = widget.focusCoordinator.replacementTarget(
      primaryTarget: widget.primaryFocusTarget,
    );
    final baseTheme = Theme.of(context);
    final extensions = [
      for (final extension in baseTheme.extensions.values)
        if (extension is! LayoutVisualTokens) extension,
      registered.bundle.tokens,
    ];
    _scheduleFocusRestore();
    return KeyedSubtree(
      key: ValueKey<String>('layout-host-${key.toString()}'),
      child: Theme(
        data: baseTheme.copyWith(extensions: extensions),
        child: LayoutPaletteScope(
          palette: widget.palette,
          child: LayoutFocusScope(
            coordinator: widget.focusCoordinator,
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
                      destination: LayoutFocusTarget(
                        semanticTarget: widget.primaryFocusTarget,
                        child: destination,
                      ),
                      onSelectDestination: widget.onSelectDestination,
                      destinationLabel: widget.destinationLabel,
                      components: registered.bundle.components,
                      tokens: registered.bundle.tokens,
                      initialFocusTarget: initialFocusTarget,
                      chrome: widget.chrome,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
