import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/environment/environment_projection_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:licoup/src/frontend/layout/layout_host.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/shell/shell_providers.dart';

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
  LayoutEnvironment? _latestMeasuredEnvironment;
  LayoutEnvironment? _latestProjectedEnvironment;
  LayoutEnvironment? _scheduledEnvironment;

  @override
  void initState() {
    super.initState();
    _agentsHomeKey = widget.renderer.createAgentsHomeKey();
    _chromeFeatures = widget.renderer.createChromeFeatures(_auxChromePanelOpen);
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
  }

  @override
  void dispose() {
    _auxChromePanelOpen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Every region stays independent: a revoked or failing region surfaces its
    // own error instead of falling back to the legacy owner value.
    return AsyncRegion<EnvironmentProjection, IntentSink<ShellIntent>>(
      source: shellEnvironmentProjectionProvider,
      actions: widget.binding.intents,
      data: (context, projectedEnvironment, _) =>
          AsyncRegion<LayoutProjection, IntentSink<ShellIntent>>(
            source: shellLayoutProjectionProvider,
            actions: widget.binding.intents,
            data: (context, layoutProjection, _) =>
                AsyncRegion<NavigationProjection, IntentSink<ShellIntent>>(
                  source: shellNavigationProjectionProvider,
                  actions: widget.binding.intents,
                  data: (context, navigationProjection, _) =>
                      AsyncRegion<StatusProjection, IntentSink<ShellIntent>>(
                        source: shellStatusProjectionProvider,
                        actions: widget.binding.intents,
                        data: (context, statusProjection, _) => _buildShell(
                          context,
                          projectedEnvironment,
                          layoutProjection,
                          navigationProjection,
                          statusProjection,
                        ),
                      ),
                ),
          ),
    );
  }

  Widget _buildShell(
    BuildContext context,
    EnvironmentProjection projectedEnvironment,
    LayoutProjection layoutProjection,
    NavigationProjection navigationProjection,
    StatusProjection statusProjection,
  ) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EffectListener<ShellEffect>(
        source: widget.binding.effects,
        onEffect: _handleEffect,
        child: LayoutBuilder(
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
            return _buildLayoutHost(
              context,
              environment,
              layoutProjection.selection,
              navigationProjection,
              statusProjection,
            );
          },
        ),
      ),
    );
  }

  Widget _buildLayoutHost(
    BuildContext context,
    LayoutEnvironment environment,
    LayoutSelectionState selection,
    NavigationProjection navigation,
    StatusProjection status,
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
        loadingBuilder: (context) => _startupLoading(context, status),
        palette: layoutPaletteFromColors(colors),
        chrome: widget.renderer.chrome,
      ),
    );
  }

  void _scheduleEnvironmentUpdate({
    required LayoutEnvironment projected,
    required LayoutEnvironment measured,
  }) {
    _latestProjectedEnvironment = projected;
    _latestMeasuredEnvironment = measured;
    if (measured == projected || measured == _scheduledEnvironment) return;
    _scheduledEnvironment = measured;
    final binding = widget.binding;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scheduledEnvironment == measured) _scheduledEnvironment = null;
      if (!mounted ||
          !identical(widget.binding, binding) ||
          _latestMeasuredEnvironment != measured ||
          _latestProjectedEnvironment == measured) {
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

Widget _startupLoading(BuildContext context, StatusProjection status) {
  if (status.errorCode.isEmpty) {
    return const Center(child: LicoLoadingIndicator());
  }
  final locale = LicoStrings.of(context);
  final message = locale.isChinese
      ? status.messageChinese
      : status.messageEnglish;
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            status.errorCode,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
