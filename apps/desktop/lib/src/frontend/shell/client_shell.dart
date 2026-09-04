import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/environment/environment_projection_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:licoup/src/frontend/layout/layout_host.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/shell/projected_layout_chrome_port.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';

class ClientShell extends StatefulWidget {
  const ClientShell({super.key, required this.binding, required this.renderer});

  final ShellBinding binding;
  final ShellRendererPort renderer;

  @override
  State<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<ClientShell>
    implements LayoutDestinationContentPort {
  late GlobalKey _agentsHomeKey;
  final LayoutFocusCoordinator _focusCoordinator = LayoutFocusCoordinator();
  final ValueNotifier<bool> _auxChromePanelOpen = ValueNotifier<bool>(false);
  late LayoutChromeFeatures _chromeFeatures;
  late ProjectedLayoutChromePort _layoutChrome;
  LayoutEnvironment? _latestMeasuredEnvironment;
  LayoutEnvironment? _scheduledEnvironment;

  @override
  void initState() {
    super.initState();
    _agentsHomeKey = widget.renderer.createAgentsHomeKey();
    _chromeFeatures = widget.renderer.createChromeFeatures(_auxChromePanelOpen);
    _layoutChrome = _createLayoutChrome();
  }

  @override
  void didUpdateWidget(ClientShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final rendererChanged = !identical(oldWidget.renderer, widget.renderer);
    if (rendererChanged) {
      _agentsHomeKey = widget.renderer.createAgentsHomeKey();
      _chromeFeatures = widget.renderer.createChromeFeatures(
        _auxChromePanelOpen,
      );
    }
    if (rendererChanged ||
        !identical(oldWidget.binding.status, widget.binding.status) ||
        !identical(oldWidget.binding.locale, widget.binding.locale)) {
      final previous = _layoutChrome;
      _layoutChrome = _createLayoutChrome();
      unawaited(previous.dispose());
    }
  }

  ProjectedLayoutChromePort _createLayoutChrome() => ProjectedLayoutChromePort(
    actions: widget.renderer.chrome,
    status: widget.binding.status,
    locale: widget.binding.locale,
  );

  @override
  void dispose() {
    unawaited(_layoutChrome.dispose());
    _auxChromePanelOpen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EffectListener<ShellEffect>(
        source: widget.binding.effects,
        onEffect: _handleEffect,
        child: ProjectionBuilder<EnvironmentProjection, EnvironmentProjection>(
          source: widget.binding.environment,
          select: _environmentProjection,
          builder: (context, projectedEnvironment) => LayoutBuilder(
            builder: (context, constraints) {
              final environment = collectLayoutEnvironment(
                context,
                constraints,
                projectedEnvironment.runtimeSurface,
              );
              _scheduleEnvironmentUpdate(
                projected: projectedEnvironment.environment,
                measured: environment,
              );
              return ProjectionBuilder<LayoutProjection, LayoutSelectionState>(
                source: widget.binding.layout,
                select: _layoutProjection,
                builder: (context, selection) =>
                    ProjectionBuilder<
                      NavigationProjection,
                      NavigationProjection
                    >(
                      source: widget.binding.navigation,
                      select: _navigationProjection,
                      builder: (context, navigation) => _buildLayoutHost(
                        context,
                        environment,
                        selection,
                        navigation,
                      ),
                    ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLayoutHost(
    BuildContext context,
    LayoutEnvironment environment,
    LayoutSelectionState selection,
    NavigationProjection navigation,
  ) {
    final colors = context.licoColors;
    return LayoutChromeFeaturesScope(
      features: _chromeFeatures,
      child: LayoutHost(
        selection: selection,
        registry: widget.renderer.layoutRegistry,
        stateStore: widget.renderer.layoutStateStore,
        environment: environment,
        destination: navigation.destination,
        availableDestinations: navigation.destinations,
        onSelectDestination: (destination) =>
            widget.binding.intents.send(SelectShellDestination(destination)),
        destinationLabel: (destination) =>
            _destinationLabel(LicoStrings.of(context), destination),
        content: this,
        focusCoordinator: _focusCoordinator,
        primaryFocusTarget: LayoutFocusTargets.primaryLandmark,
        loadingBuilder: (_) => const Center(child: CircularProgressIndicator()),
        palette: layoutPaletteFromColors(colors),
        chrome: _layoutChrome,
      ),
    );
  }

  void _scheduleEnvironmentUpdate({
    required LayoutEnvironment projected,
    required LayoutEnvironment measured,
  }) {
    _latestMeasuredEnvironment = measured;
    if (measured == projected || measured == _scheduledEnvironment) return;
    _scheduledEnvironment = measured;
    final binding = widget.binding;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scheduledEnvironment == measured) _scheduledEnvironment = null;
      if (!mounted ||
          !identical(widget.binding, binding) ||
          _latestMeasuredEnvironment != measured ||
          binding.environment.current.environment == measured) {
        return;
      }
      binding.intents.send(UpdateShellLayoutEnvironment(measured));
    });
  }

  void _handleEffect(ShellEffect effect) {
    if (effect case ShellDestinationReselected(
      destination: ClientSection.agents,
    )) {
      widget.renderer.resetAgentsHome(_agentsHomeKey);
    }
  }

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) =>
      widget.renderer.buildDestination(
        context,
        destination,
        agentsHomeKey: _agentsHomeKey,
      );

  String _destinationLabel(LicoStrings strings, ClientSection section) =>
      switch (section) {
        ClientSection.agents => strings.agents,
        ClientSection.monitoring => strings.tokenUsage,
        ClientSection.skillHub => strings.skillHub,
        ClientSection.pluginManagement => strings.pluginManagement,
        ClientSection.mobileRelay => strings.mobileRelay,
        ClientSection.models => strings.modelGateway,
        ClientSection.settings => strings.settings,
        ClientSection.agentHub => strings.agentHub,
      };
}

EnvironmentProjection _environmentProjection(EnvironmentProjection value) =>
    value;

LayoutSelectionState _layoutProjection(LayoutProjection value) =>
    value.selection;

NavigationProjection _navigationProjection(NavigationProjection value) => value;
