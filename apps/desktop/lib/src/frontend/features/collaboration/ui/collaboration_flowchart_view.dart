import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_cards.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_header.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_overlays.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_paint.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_scene.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_style.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_world.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_graph_layout.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass_region.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_binding.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_effect.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_intent.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';

/// Collaboration run flowchart: revision chain, node cards, decision gates,
/// held proposals, and the plan-history drawer over one conversation's run.
final class CollaborationFlowchartView extends StatefulWidget {
  const CollaborationFlowchartView({
    super.key,
    required this.binding,
    this.title,
  });

  final CollaborationBinding binding;

  /// Heading for the empty states; defaults to the feature title.
  final String? title;

  @override
  State<CollaborationFlowchartView> createState() =>
      _CollaborationFlowchartViewState();
}

final class _CollaborationFlowchartViewState
    extends State<CollaborationFlowchartView>
    with TickerProviderStateMixin {
  late final TransformationController _view = TransformationController();
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: LicoMotion.loopLong,
  );
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: LicoMotion.loopShort,
  );

  /// Plan-change moment: canvas sweep plus the added cards' entrance.
  late final AnimationController _planChange = AnimationController(
    vsync: this,
    // Starts settled: cards render at full opacity until the first
    // plan-change sweep runs forward from zero.
    value: 1,
  );
  late final CurvedAnimation _entrance = CurvedAnimation(
    parent: _planChange,
    curve: const Interval(0.1, 0.7, curve: LicoMotion.decelerate),
  );
  late final CurvedAnimation _drawIn = CurvedAnimation(
    parent: _planChange,
    curve: const Interval(0, 0.6),
  );

  /// Route fade-in after the layout moved.
  late final AnimationController _relayout = AnimationController(
    vsync: this,
    value: 1,
  );

  /// One dot along each route that just started carrying work.
  late final AnimationController _dispatch = AnimationController(
    vsync: this,
    value: 1,
  );

  final TextEditingController _noteController = TextEditingController();
  final Map<String, FocusNode> _cardFocus = {};
  final ValueNotifier<String?> _hovered = ValueNotifier(null);

  bool _compare = false;
  bool _follow = true;
  bool _historyOpen = false;
  bool _settingsOpen = false;
  bool _reviseOpen = false;
  String? _popoverCard;
  int _bannerDismissedHead = -1;
  Timer? _bannerTimer;
  Size _viewport = Size.zero;
  bool _didInitialFit = false;

  /// Head when the view first saw the run; the applied/reverted banner only
  /// appears for revisions that land while the view is mounted.
  int _mountedHead = -1;

  CollaborationProjection? _projection;
  CollaborationFlowchartScene? _scene;
  Object? _sceneGraph;
  Object? _sceneStates;
  Object? _sceneDiff;
  Object? _sceneProposal;
  bool? _sceneCompare;
  LicoStrings? _sceneStrings;
  CollaborationCardMetrics? _metrics;
  Set<String> _entering = const {};
  Set<String> _drawInKeys = const {};
  Set<String> _dispatchKeys = const {};

  @override
  void initState() {
    super.initState();
    // The hover readout must not rebuild the canvas.
    _hovered.addListener(_onHoverChanged);
  }

  void _onHoverChanged() {
    // Cleared when the canvas rebuilds without the hovered card.
    final scene = _scene;
    final id = _hovered.value;
    if (scene != null && id != null && scene.layout.cardFor(id) == null) {
      _hovered.value = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Text scale or theme changes invalidate the measurement cache.
    _metrics = null;
    _syncAmbientMotion();
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _hovered.dispose();
    _view.dispose();
    _ambient.dispose();
    _spin.dispose();
    _planChange.dispose();
    _entrance.dispose();
    _drawIn.dispose();
    _relayout.dispose();
    _dispatch.dispose();
    _noteController.dispose();
    for (final node in _cardFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  IntentSink<CollaborationIntent> get _intents => widget.binding.intents;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return EffectListener<CollaborationEffect>(
      source: widget.binding.effects,
      onEffect: (effect) => _handleEffect(effect, strings),
      child:
          ProjectionBuilder<CollaborationProjection, CollaborationProjection>(
            source: widget.binding.projection,
            select: (projection) => projection,
            builder: (context, projection) {
              final scene = _observe(context, projection);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CollaborationHeaderBar(
                    projection: projection,
                    title: widget.title ?? strings.collaborationTitle,
                    compare: _compare,
                    follow: _follow,
                    historyOpen: _historyOpen,
                    settingsOpen: _settingsOpen,
                    onCompareChanged: (value) =>
                        setState(() => _compare = value),
                    onFollowChanged: (value) => setState(() => _follow = value),
                    onToggleHistory: () =>
                        setState(() => _historyOpen = !_historyOpen),
                    onToggleSettings: () =>
                        setState(() => _settingsOpen = !_settingsOpen),
                  ),
                  Expanded(child: _canvas(context, projection, scene)),
                ],
              );
            },
          ),
    );
  }

  void _handleEffect(CollaborationEffect effect, LicoStrings strings) {
    if (!mounted) return;
    switch (effect) {
      case CollaborationCommandConflicted(:final currentHead):
        showLicoToast(
          context,
          message: strings.collaborationConflictNotice(currentHead),
          kind: LicoToastKind.error,
        );
      case CollaborationCommandRejected(:final code):
        showLicoToast(
          context,
          message: strings.collaborationErrorMessage(code),
          kind: LicoToastKind.error,
        );
    }
  }

  /// Rebuilds the cached scene when the inputs changed and derives the
  /// transient effects (sweep, relayout, dispatch dots) from the delta.
  CollaborationFlowchartScene? _observe(
    BuildContext context,
    CollaborationProjection projection,
  ) {
    final strings = LicoStrings.of(context);
    _metrics ??= CollaborationCardMetrics.of(context);
    final active = projection.isActive && projection.graph != null;
    if (!active) return null;
    final graph = projection.graph!;
    final states = projection.nodeStates;
    final diff = projection.headDiff;
    final proposal = projection.proposal;
    final changed =
        !identical(graph, _sceneGraph) ||
        !identical(states, _sceneStates) ||
        !identical(diff, _sceneDiff) ||
        !identical(proposal, _sceneProposal) ||
        _sceneCompare != _compare ||
        !identical(strings, _sceneStrings);
    if (!changed) {
      _projection = projection;
      return _scene;
    }

    final previous = _scene;
    final previousProjection = _projection;
    final previousWasActive = previousProjection?.isActive ?? false;
    if (!previousWasActive) _mountedHead = projection.headNumber;
    final scene = CollaborationFlowchartScene.of(
      projection,
      compare: _compare,
      strings: strings,
      metrics: _metrics!,
    );
    _scene = scene;
    _sceneGraph = graph;
    _sceneStates = states;
    _sceneDiff = diff;
    _sceneProposal = proposal;
    _sceneCompare = _compare;
    _sceneStrings = strings;

    _entering = const {};
    _drawInKeys = const {};
    _dispatchKeys = const {};
    final headIncreased =
        previousWasActive &&
        projection.viewingHead &&
        projection.headNumber > previousProjection!.headNumber;
    if (headIncreased) {
      final headDiff = projection.headDiff;
      _entering = scene.displayIdsFor(headDiff?.addedNodes ?? const []);
      _drawInKeys = scene.routeKeysFor(headDiff?.addedEdges ?? const []);
    }
    if (previous != null) {
      _dispatchKeys = scene.activeRouteKeys
          .difference(previous.activeRouteKeys)
          .toSet();
    }

    final layoutMoved =
        previous != null && !_sameLayout(previous.layout, scene.layout);
    final popover = _popoverCard;
    if (popover != null && scene.layout.cardFor(popover) == null) {
      _popoverCard = null;
    }
    _projection = projection;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (headIncreased) _runPlanChange();
      if (layoutMoved) _runRelayout();
      if (_dispatchKeys.isNotEmpty) _runDispatch();
      _syncAmbientMotion();
      if (!_didInitialFit) {
        _didInitialFit = true;
        _showAtUnitScale(scene);
      } else if (_follow && projection.viewingHead) {
        _centerOnFollow(scene);
      }
    });
    return scene;
  }

  void _runPlanChange() {
    final duration = context.motion(const Duration(milliseconds: 1500));
    if (duration <= Duration.zero) return;
    _planChange
      ..duration = duration
      ..forward(from: 0);
  }

  void _runRelayout() {
    final duration = context.motion(LicoMotion.long);
    if (duration <= Duration.zero) return;
    _relayout
      ..duration = duration
      ..forward(from: 0);
  }

  void _runDispatch() {
    final duration = context.motion(LicoMotion.loopShort);
    if (duration <= Duration.zero) return;
    _dispatch
      ..duration = duration
      ..forward(from: 0);
  }

  void _syncAmbientMotion() {
    final live = _scene?.live ?? false;
    if (live && context.allowsAmbientMotion) {
      if (!_ambient.isAnimating) _ambient.repeat();
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      if (_ambient.isAnimating) _ambient.stop();
      if (_spin.isAnimating) _spin.stop();
    }
  }

  bool _sameLayout(CollaborationGraphLayout a, CollaborationGraphLayout b) {
    if (a.worldSize != b.worldSize || a.cards.length != b.cards.length) {
      return false;
    }
    for (var i = 0; i < a.cards.length; i++) {
      if (a.cards[i].id != b.cards[i].id ||
          a.cards[i].rect != b.cards[i].rect) {
        return false;
      }
    }
    return true;
  }

  CollaborationCardAnimations get _animations => CollaborationCardAnimations(
    ambient: _ambient,
    spin: _spin,
    enabled: context.allowsAmbientMotion,
  );

  FocusNode _focusNodeFor(String cardId) =>
      _cardFocus.putIfAbsent(cardId, FocusNode.new);

  double get _scale => _view.value.getMaxScaleOnAxis();

  void _zoomAt(Offset focal, double factor) {
    final next = (_scale * factor).clamp(0.2, 2.0);
    final matrix = _view.value.clone();
    matrix.translateByDouble(focal.dx, focal.dy, 0, 1);
    matrix.scaleByDouble(next / _scale, next / _scale, 1, 1);
    matrix.translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _view.value = matrix;
  }

  void _centerWorld(Offset world) {
    if (_viewport.isEmpty) return;
    final scale = _scale;
    _view.value = Matrix4.identity()
      ..translateByDouble(
        _viewport.width / 2 - world.dx * scale,
        _viewport.height / 2 - world.dy * scale,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void _centerOnFollow(CollaborationFlowchartScene scene) {
    final target = scene.followTarget;
    if (target == null) return;
    final card = scene.layout.cardFor(target);
    if (card != null) _centerWorld(card.rect.center);
  }

  /// The initial view: zoom 1.0 centred on the follow target — the active
  /// node — or on the graph centre when nothing is running. Fit stays on
  /// demand via the fit button.
  void _showAtUnitScale(CollaborationFlowchartScene scene) {
    if (_viewport.isEmpty) return;
    final follow = scene.followTarget;
    final card = follow == null ? null : scene.layout.cardFor(follow);
    final world =
        card?.rect.center ?? scene.layout.worldSize.center(Offset.zero);
    _view.value = Matrix4.identity()
      ..translateByDouble(
        _viewport.width / 2 - world.dx,
        _viewport.height / 2 - world.dy,
        0,
        1,
      );
  }

  void _fit() {
    final scene = _scene;
    if (scene == null || _viewport.isEmpty) return;
    final resolved =
        (0.94 *
                math.min(
                  _viewport.width / scene.layout.worldSize.width,
                  _viewport.height / scene.layout.worldSize.height,
                ))
            .clamp(0.2, 1.0)
            .toDouble();
    _view.value = Matrix4.identity()
      ..translateByDouble(
        (_viewport.width - scene.layout.worldSize.width * resolved) / 2,
        (_viewport.height - scene.layout.worldSize.height * resolved) / 2,
        0,
        1,
      )
      ..scaleByDouble(resolved, resolved, resolved, 1);
  }

  Widget _canvas(
    BuildContext context,
    CollaborationProjection projection,
    CollaborationFlowchartScene? scene,
  ) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    if (scene == null) {
      return switch (projection.availability) {
        CollaborationAvailability.loading => const Center(
          child: LicoLoadingIndicator(strokeWidth: 2.5),
        ),
        CollaborationAvailability.unavailable => LicoEmptyState(
          icon: Icons.account_tree_outlined,
          title: strings.collaborationUnavailable,
        ),
        _ => LicoEmptyState(
          icon: Icons.account_tree_outlined,
          title: strings.collaborationNone,
        ),
      };
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        final banner = _bannerKind(projection);
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: LicoGlassRegion.hostsContent(context)
                    ? const Color(0x00000000)
                    : colors.isDark
                    ? colors.background
                    : colors.surfaceSunken,
                child: CustomPaint(
                  painter: CollaborationGridPainter(
                    transform: _view,
                    color: colors.isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFF966E46).withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _view,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(560),
                minScale: 0.2,
                maxScale: 2,
                child: CollaborationFlowchartWorld(
                  scene: scene,
                  metrics: _metrics!,
                  animations: _animations,
                  effects: CollaborationWorldEffects(
                    relayout: _relayout,
                    entrance: _entrance,
                    entering: _entering,
                    drawIn: _drawIn,
                    drawInKeys: _drawInKeys,
                    dispatch: _dispatch,
                    dispatchKeys: _dispatchKeys,
                  ),
                  hovered: _hovered,
                  focusNodeFor: _focusNodeFor,
                  onOpen: (cardId) => setState(() => _popoverCard = cardId),
                  onBackgroundTap: () => setState(() => _popoverCard = null),
                ),
              ),
            ),
            if (_popoverCard != null) _popover(context, scene, projection),
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: CollaborationSweepPainter(
                      progress: _planChange,
                      colors: colors,
                    ),
                  ),
                ),
              ),
            ),
            if (banner != null)
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: CollaborationFlowchartBanner(
                  kind: banner,
                  projection: projection,
                  pending: projection.commandPending,
                  reviseOpen: _reviseOpen,
                  noteController: _noteController,
                  onApprove: () =>
                      _intents.send(const ApproveCollaborationProposal()),
                  onReject: () =>
                      _intents.send(const RejectCollaborationProposal()),
                  onReviseTap: () => setState(() => _reviseOpen = true),
                  onReviseSubmit: _requestRevision,
                  onViewChanges: () => setState(() => _compare = true),
                  onReplay: _runPlanChange,
                  onRevert: () => _intents.send(
                    RevertCollaborationRevision(
                      projection.head?.parent ?? projection.headNumber - 1,
                    ),
                  ),
                  onRestore: () => _intents.send(
                    RevertCollaborationRevision(projection.viewedNumber!),
                  ),
                  onBackToHead: () =>
                      _intents.send(const SelectCollaborationRevision(null)),
                  onDismiss: () => setState(() {
                    if (_reviseOpen) {
                      _reviseOpen = false;
                      _noteController.clear();
                    } else {
                      _bannerDismissedHead = projection.headNumber;
                    }
                  }),
                ),
              ),
            Positioned(
              right: 12,
              bottom: 92,
              child: CollaborationZoomHud(
                onZoomIn: () => _zoomAt(_viewport.center(Offset.zero), 1.2),
                onZoomOut: () =>
                    _zoomAt(_viewport.center(Offset.zero), 1 / 1.2),
                onFit: _fit,
              ),
            ),
            Positioned(
              right: 12,
              bottom: 12,
              child: CollaborationMinimap(
                cards: scene.minimapCards,
                world: scene.layout.worldSize,
                transform: _view,
                viewport: _viewport,
                onPanTo: _centerWorld,
              ),
            ),
            AnimatedPositioned(
              duration: context.motion(LicoMotion.medium),
              curve: LicoMotion.standard,
              top: 0,
              bottom: 0,
              right: _historyOpen ? 0 : -CollaborationHistoryDrawer.width - 32,
              width: CollaborationHistoryDrawer.width,
              child: CollaborationHistoryDrawer(
                projection: projection,
                compare: _compare,
                pending: projection.commandPending,
                onCompareChanged: (value) => setState(() => _compare = value),
                onSelect: (number) => _intents.send(
                  SelectCollaborationRevision(number < 0 ? null : number),
                ),
                onRevert: (number) =>
                    _intents.send(RevertCollaborationRevision(number)),
                onClose: () => setState(() => _historyOpen = false),
              ),
            ),
            if (_settingsOpen) ...[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _settingsOpen = false),
                ),
              ),
              Positioned(
                top: 8,
                right: 12,
                child: CollaborationSettingsMenu(
                  projection: projection,
                  compact:
                      _viewport.width < CollaborationHeaderBar.compactWidth,
                  compare: _compare,
                  follow: _follow,
                  onCompareChanged: (value) => setState(() => _compare = value),
                  onFollowChanged: (value) => setState(() => _follow = value),
                  onPlanChangePolicy: (policy) =>
                      _intents.send(SetCollaborationPlanChangePolicy(policy)),
                  onGateReviewPolicy: (policy) =>
                      _intents.send(SetCollaborationGateReviewPolicy(policy)),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  CollaborationBannerKind? _bannerKind(CollaborationProjection projection) {
    if (projection.viewingHead && projection.proposal != null) {
      return CollaborationBannerKind.proposal;
    }
    if (!projection.viewingHead) {
      return CollaborationBannerKind.historical;
    }
    final head = projection.head;
    if (head == null ||
        head.number <= _mountedHead ||
        _bannerDismissedHead == head.number) {
      return null;
    }
    if (head.revertOf != null) {
      _scheduleBannerDismiss(head.number);
      return CollaborationBannerKind.reverted;
    }
    if (head.approval == CollaborationRevisionApproval.autoApplied &&
        projection.headNumber > 1) {
      _scheduleBannerDismiss(head.number);
      return CollaborationBannerKind.applied;
    }
    return null;
  }

  /// The applied/reverted banner steps aside after a few seconds.
  void _scheduleBannerDismiss(int headNumber) {
    if (_bannerTimer?.isActive ?? false) return;
    _bannerTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _bannerDismissedHead == headNumber) return;
      setState(() => _bannerDismissedHead = headNumber);
    });
  }

  void _requestRevision(String note) {
    final trimmed = note.trim();
    if (trimmed.isEmpty) return;
    _intents.send(RequestCollaborationRevision(trimmed));
    setState(() {
      _reviseOpen = false;
      _noteController.clear();
    });
  }

  Widget _popover(
    BuildContext context,
    CollaborationFlowchartScene scene,
    CollaborationProjection projection,
  ) {
    final cardId = _popoverCard!;
    final card = scene.layout.cardFor(cardId);
    if (card == null) return const SizedBox.shrink();
    final model = scene.models[cardId];
    final task = switch (model) {
      CollaborationTaskCardModel() => model,
      CollaborationStackCardModel() => collaborationTaskModel(
        scene.plan,
        scene.detailNodeFor(cardId),
        LicoStrings.of(context),
      ),
      _ => null,
    };
    if (task == null) return const SizedBox.shrink();
    const width = CollaborationNodePopover.width;
    final world = scene.layout.worldSize;
    final right = card.rect.right + 10 + width <= world.width - 4;
    final left = right
        ? card.rect.right + 10
        : math.max(4.0, card.rect.left - 10 - width);
    final top = card.rect.top.clamp(8.0, math.max(8.0, world.height - 200));
    return Positioned(
      left: left,
      top: top.toDouble(),
      child: CollaborationNodePopover(
        model: task,
        metrics: _metrics!,
        pending: projection.commandPending,
        onGateOption: (gateId, optionId) {
          _intents.send(DecideCollaborationGate(gateId, optionId));
          setState(() => _popoverCard = null);
        },
        onClose: () {
          setState(() => _popoverCard = null);
          _focusNodeFor(cardId).requestFocus();
        },
      ),
    );
  }
}
