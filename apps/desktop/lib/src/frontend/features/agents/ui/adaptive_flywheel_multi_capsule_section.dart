import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_editor_models.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_target_catalog.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Reusable Adaptive Flywheel multi-capsule picker.
///
/// Title sits outside, above a stadium (full-pill) shell that matches the
/// inner assignment capsules. Collapsed: circular plus. Expanded: the shell
/// stays a single row (chips + draft field + confirm); agent / model /
/// reasoning cards float via a root [OverlayPortal] (flip above
/// when space below is tight) and do not resize the stadium. The draft field
/// mirrors cascade picks: agent icon and `Agent · Model · Effort`.
final class AdaptiveFlywheelMultiCapsuleSection extends StatefulWidget {
  const AdaptiveFlywheelMultiCapsuleSection({
    super.key,
    required this.title,
    required this.keyPrefix,
    required this.idPrefix,
    required this.assignments,
    required this.targets,
    required this.onChanged,
    this.showFast = false,
    this.highlightFirstAsCurrentConversation = false,
    this.description = '',
    this.isRefreshingAgentCatalog,
    this.onAgentCatalogRequested,
  });

  final String title;
  final String description;
  final String keyPrefix;
  final String idPrefix;
  final bool showFast;

  /// When true, the first capsule draws a Current Conversation accent border.
  final bool highlightFirstAsCurrentConversation;
  final List<DailyConversationAgentAssignment> assignments;
  final List<TargetCandidate> targets;
  final ValueChanged<List<DailyConversationAgentAssignment>> onChanged;
  final bool Function(String agentId)? isRefreshingAgentCatalog;
  final ValueChanged<String>? onAgentCatalogRequested;

  @override
  State<AdaptiveFlywheelMultiCapsuleSection> createState() =>
      _AdaptiveFlywheelMultiCapsuleSectionState();
}

final class _AdaptiveFlywheelMultiCapsuleSectionState
    extends State<AdaptiveFlywheelMultiCapsuleSection> {
  static const double _circleExtent = 32;
  static const double _capsuleWidth = 260;
  static const double _cascadeGap = 10;
  static const double _cascadePreferredHeight = 260;
  static const double _cascadeMinHeight = 140;

  final TextEditingController _queryController = TextEditingController();
  late final FocusNode _inputFocus = FocusNode(
    debugLabel: '${widget.keyPrefix}-search',
  );
  final GlobalKey _stadiumKey = GlobalKey();
  final LayerLink _stadiumLink = LayerLink();
  final OverlayPortalController _cascadePortalController =
      OverlayPortalController();
  bool _expanded = false;
  bool _inputFocused = false;
  bool _syncingDraftLabel = false;

  /// In-progress selection; committed only by the checkmark control.
  DailyConversationAgentAssignment _draft =
      const DailyConversationAgentAssignment();

  @override
  void initState() {
    super.initState();
    _queryController.addListener(() {
      if (_syncingDraftLabel || !mounted) return;
      setState(() {});
    });
    _inputFocus.addListener(_onInputFocusChanged);
  }

  @override
  void dispose() {
    if (_cascadePortalController.isShowing) {
      _cascadePortalController.hide();
    }
    _inputFocus.removeListener(_onInputFocusChanged);
    _queryController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onInputFocusChanged() {
    final focused = _inputFocus.hasFocus;
    if (focused == _inputFocused || !mounted) return;
    setState(() => _inputFocused = focused);
  }

  /// Agent-only seed so the stadium field fills progressively as the user
  /// picks model and reasoning effort in the cascade.
  DailyConversationAgentAssignment _draftForTarget(TargetCandidate target) {
    return DailyConversationAgentAssignment(agentId: target.target);
  }

  String _newAssignmentId(String agentId) {
    return '${widget.idPrefix}-$agentId-${DateTime.now().microsecondsSinceEpoch}';
  }

  String _draftFieldLabel(LicoStrings strings) {
    final target = _targetById(_draft.agentId);
    if (target == null && _draft.agentId.trim().isEmpty) {
      return '';
    }
    final agentLabel = target == null
        ? _draft.agentId.trim()
        : agentConversationTargetDisplayName(target);
    return composeOrchestrationAssignmentCapsuleLabel(
      agentLabel: agentLabel,
      modelName: _draft.modelName,
      reasoningEffort: _draft.reasoningEffort,
      fast: widget.showFast && _draft.fast,
      fastLabel: strings.fastModeLabel,
      effortLabel: (effort) =>
          strings.reasoningEffortOptionLabel(effort, effort),
      modelDisplayName: target == null
          ? null
          : (model) => agentOrchestrationModelDisplayName(target, model),
    );
  }

  void _syncDraftLabelIntoField([LicoStrings? strings]) {
    final resolved = strings ?? LicoStrings.of(context);
    final label = _draftFieldLabel(resolved);
    if (_queryController.text == label) return;
    _syncingDraftLabel = true;
    _queryController.value = TextEditingValue(
      text: label,
      selection: TextSelection.collapsed(offset: label.length),
    );
    _syncingDraftLabel = false;
  }

  void _setDraft(DailyConversationAgentAssignment draft) {
    setState(() => _draft = draft);
    _syncDraftLabelIntoField();
  }

  DailyConversationAgentAssignment _draftWithConfirmDefaults(
    DailyConversationAgentAssignment draft,
  ) {
    final agentId = draft.agentId.trim();
    if (agentId.isEmpty) return draft;
    final target = _targetById(agentId);
    if (target == null) return draft;
    var next = draft;
    if (next.modelName.trim().isEmpty) {
      final models = agentOrchestrationCommanderModels(target);
      next = next.copyWith(modelName: models.isEmpty ? '' : models.first);
    }
    if (next.reasoningEffort.trim().isEmpty) {
      final efforts = agentOrchestrationReasoningEffortsForModel(
        target,
        next.modelName,
      );
      next = next.copyWith(
        reasoningEffort: efforts.isEmpty ? '' : efforts.first,
      );
    }
    return next;
  }

  void _openPicker() {
    if (_expanded) return;
    setState(() {
      _expanded = true;
      _draft = const DailyConversationAgentAssignment();
      _queryController.clear();
    });
    if (widget.targets.isNotEmpty) {
      widget.onAgentCatalogRequested?.call(widget.targets.first.target);
    }
    _cascadePortalController.show();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final stadiumContext = _stadiumKey.currentContext;
      if (stadiumContext != null) {
        // Keep the stadium in view with room for the floating cascade.
        await Scrollable.ensureVisible(
          stadiumContext,
          alignment: 0.35,
          duration: context.motion(LicoMotion.medium),
          curve: LicoMotion.decelerate,
        );
        if (mounted && _expanded) setState(() {});
      }
      if (mounted) _inputFocus.requestFocus();
    });
  }

  /// Prefer below the stadium; flip above when the window has more room there.
  ({bool openUpward, double maxCardHeight}) _cascadePlacement() {
    final box = _stadiumKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return (openUpward: false, maxCardHeight: _cascadePreferredHeight);
    }
    final origin = box.localToGlobal(Offset.zero);
    final media = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final spaceBelow =
        media.height -
        padding.bottom -
        (origin.dy + box.size.height) -
        _cascadeGap;
    final spaceAbove = origin.dy - padding.top - _cascadeGap;
    final openUpward =
        spaceBelow < _cascadePreferredHeight && spaceAbove > spaceBelow;
    final available = openUpward ? spaceAbove : spaceBelow;
    return (
      openUpward: openUpward,
      maxCardHeight: available.clamp(
        _cascadeMinHeight,
        _cascadePreferredHeight,
      ),
    );
  }

  void _closePicker() {
    if (!_expanded && _queryController.text.isEmpty) return;
    if (_cascadePortalController.isShowing) {
      _cascadePortalController.hide();
    }
    setState(() {
      _expanded = false;
      _queryController.clear();
      _draft = const DailyConversationAgentAssignment();
    });
    _inputFocus.unfocus();
  }

  void _confirmDraft() {
    final agentId = _draft.agentId.trim();
    if (agentId.isEmpty) return;
    final resolved = _draftWithConfirmDefaults(_draft);
    final entry = resolved.copyWith(id: _newAssignmentId(agentId));
    widget.onChanged(List.unmodifiable([...widget.assignments, entry]));
    _closePicker();
  }

  void _removeAssignment(String assignmentId) {
    widget.onChanged(
      List.unmodifiable([
        for (final assignment in widget.assignments)
          if (assignment.id != assignmentId) assignment,
      ]),
    );
  }

  void _reorderAssignments(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= widget.assignments.length) return;
    final next = [...widget.assignments];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), moved);
    widget.onChanged(List.unmodifiable(next));
  }

  void _selectDraftAgent(TargetCandidate target) {
    widget.onAgentCatalogRequested?.call(target.target);
    _setDraft(_draftForTarget(target));
  }

  List<TargetCandidate> get _filteredTargets {
    // Once a cascade agent is chosen, the field shows the draft path and must
    // not filter the agent list by that composed label.
    if (_draft.agentId.trim().isNotEmpty) return widget.targets;
    final query = _queryController.text.trim().toLowerCase();
    if (query.isEmpty) return widget.targets;
    return [
      for (final target in widget.targets)
        if (agentConversationTargetDisplayName(
              target,
            ).toLowerCase().contains(query) ||
            target.target.toLowerCase().contains(query))
          target,
    ];
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closePicker();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final motion = context.motion(LicoMotion.medium);
    final filtered = _filteredTargets;
    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    final selectedIds = {
      for (final assignment in widget.assignments) assignment.agentId,
    };

    // Root overlay paints above the dialog footer so Membership cards are not
    // covered by Cancel/Save. Flip upward when space below is tight.
    return OverlayPortal(
      controller: _cascadePortalController,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context) {
        final placement = _cascadePlacement();
        // Overlay gives tight full-screen constraints; Align shrink-wraps so
        // follower anchors resolve against the card size, not the viewport.
        return Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _stadiumLink,
            targetAnchor: placement.openUpward
                ? Alignment.topLeft
                : Alignment.bottomLeft,
            followerAnchor: placement.openUpward
                ? Alignment.bottomLeft
                : Alignment.topLeft,
            offset: Offset(
              0,
              placement.openUpward ? -_cascadeGap : _cascadeGap,
            ),
            showWhenUnlinked: false,
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              child: AgentRuntimeAssignmentCascadeCards(
                keyPrefix: widget.keyPrefix,
                showFast: widget.showFast,
                borderRadius: menuRadius,
                maxHeight: placement.maxCardHeight,
                targets: filtered,
                draft: _draft,
                selectedAgentIds: selectedIds,
                onDraftChanged: _setDraft,
                isRefreshingAgentCatalog: widget.isRefreshingAgentCatalog,
                onAgentCatalogRequested: widget.onAgentCatalogRequested,
              ),
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          if (widget.description.trim().isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              widget.description,
              style: TextStyle(color: colors.textMuted, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          CompositedTransformTarget(
            key: _stadiumKey,
            link: _stadiumLink,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // Recess the stadium shell with a black veil over the dialog wash.
                color: Color.alphaBlend(
                  ConversationVisualTokens.adaptiveFlywheelStadiumVeil(colors),
                  colors.surfaceLow,
                ),
                // Match inner assignment capsules (stadium / full pill).
                borderRadius: kComposerCapsuleBorderRadius,
                border: Border.all(
                  color: colors.line.withAlpha(colors.isDark ? 90 : 130),
                ),
              ),
              child: ClipRRect(
                borderRadius: kComposerCapsuleBorderRadius,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  // Single-row shell only — cascade cards float in the overlay.
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (widget.assignments.isNotEmpty) ...[
                        Flexible(
                          child: SizedBox(
                            height: _circleExtent,
                            child: ReorderableListView.builder(
                              key: Key('${widget.keyPrefix}-order'),
                              scrollDirection: Axis.horizontal,
                              shrinkWrap: true,
                              buildDefaultDragHandles: false,
                              proxyDecorator: _capsuleProxyDecorator,
                              onReorderItem: _reorderAssignments,
                              itemCount: widget.assignments.length,
                              itemBuilder: (context, index) {
                                final assignment = widget.assignments[index];
                                return Padding(
                                  key: ValueKey<String>(
                                    '${widget.keyPrefix}-order-${assignment.id}',
                                  ),
                                  padding: EdgeInsets.only(
                                    right:
                                        index == widget.assignments.length - 1
                                        ? 0
                                        : 8,
                                  ),
                                  child: ReorderableDelayedDragStartListener(
                                    index: index,
                                    child: _SelectedAgentCapsule(
                                      keyPrefix: widget.keyPrefix,
                                      assignment: assignment,
                                      target: _targetById(assignment.agentId),
                                      isCurrentConversation:
                                          widget
                                              .highlightFirstAsCurrentConversation &&
                                          index == 0,
                                      onRemove: () =>
                                          _removeAssignment(assignment.id),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // Plus / search capsule sits after saved chips; the confirm
                      // checkmark sits immediately to its right while expanded.
                      Focus(
                        onKeyEvent: _onKeyEvent,
                        child: AnimatedContainer(
                          key: Key('${widget.keyPrefix}-picker'),
                          duration: motion,
                          curve: LicoMotion.decelerate,
                          width: _expanded ? _capsuleWidth : _circleExtent,
                          height: _circleExtent,
                          child: ClipRect(
                            child: OverflowBox(
                              minWidth: 0,
                              maxWidth: _capsuleWidth,
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: _expanded
                                    ? _capsuleWidth
                                    : _circleExtent,
                                height: _circleExtent,
                                child: _expanded
                                    ? _SearchStyleCapsule(
                                        focused: _inputFocused,
                                        child: _CapsuleSearchField(
                                          keyPrefix: widget.keyPrefix,
                                          controller: _queryController,
                                          focusNode: _inputFocus,
                                          hintText: strings.sidebarSearchHint,
                                          selectedTarget: _targetById(
                                            _draft.agentId,
                                          ),
                                          readOnly: _draft.agentId
                                              .trim()
                                              .isNotEmpty,
                                          onClose: _closePicker,
                                          onSubmitted: (raw) {
                                            final match = _firstMatch(raw);
                                            if (match != null) {
                                              _selectDraftAgent(match);
                                            }
                                          },
                                        ),
                                      )
                                    : AppleGlassSurface(
                                        borderRadius: BorderRadius.circular(
                                          _circleExtent / 2,
                                        ),
                                        fillAlpha: colors.isDark ? 22 : 10,
                                        child: Tooltip(
                                          message:
                                              strings.addDailyConversationAgent,
                                          waitDuration: LicoMotion.tooltipWait,
                                          child: InkWell(
                                            key: Key('${widget.keyPrefix}-add'),
                                            customBorder: const CircleBorder(),
                                            onTap: _openPicker,
                                            child: Center(
                                              child: Icon(
                                                Icons.add_rounded,
                                                size: 18,
                                                color: colors.textMuted
                                                    .withAlpha(220),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_expanded) ...[
                        const SizedBox(width: 8),
                        AppleGlassSurface(
                          borderRadius: BorderRadius.circular(
                            _circleExtent / 2,
                          ),
                          fillAlpha: colors.isDark ? 22 : 10,
                          focused: _draft.agentId.trim().isNotEmpty,
                          focusColor: colors.accent,
                          child: Tooltip(
                            message: strings.confirmDailyConversationSelection,
                            waitDuration: LicoMotion.tooltipWait,
                            child: InkWell(
                              key: Key('${widget.keyPrefix}-confirm'),
                              customBorder: const CircleBorder(),
                              onTap: _draft.agentId.trim().isEmpty
                                  ? null
                                  : _confirmDraft,
                              child: SizedBox.square(
                                dimension: _circleExtent,
                                child: Icon(
                                  Icons.check_rounded,
                                  size: 18,
                                  color: _draft.agentId.trim().isEmpty
                                      ? colors.textMuted.withAlpha(120)
                                      : colors.accent,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  TargetCandidate? _targetById(String agentId) {
    for (final target in widget.targets) {
      if (target.target == agentId) return target;
    }
    return null;
  }

  Widget _capsuleProxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(animation.value);
        return Transform.scale(
          scale: 1.0 + (0.04 * t),
          child: Opacity(opacity: 0.92 + (0.08 * t), child: child),
        );
      },
      child: child,
    );
  }

  TargetCandidate? _firstMatch(String raw) {
    final query = raw.trim().toLowerCase();
    if (query.isEmpty) {
      return _filteredTargets.isEmpty ? null : _filteredTargets.first;
    }
    for (final target in _filteredTargets) {
      final label = agentConversationTargetDisplayName(target).toLowerCase();
      if (label == query || target.target.toLowerCase() == query) {
        return target;
      }
    }
    return _filteredTargets.isEmpty ? null : _filteredTargets.first;
  }
}

/// Shared Agent → model → reasoning assignment cards used by workflow actor
/// bindings and the independent Assistant Profile card. The model card has a
/// contains-match search field; once a model is confirmed the reasoning-effort
/// card tracks it instead of the hovered model. [revealSelectionOnOpen]
/// scrolls each column's persisted selection into view.
final class AgentRuntimeAssignmentCascadeCards extends StatefulWidget {
  const AgentRuntimeAssignmentCascadeCards({
    super.key,
    required this.keyPrefix,
    required this.showFast,
    required this.borderRadius,
    required this.maxHeight,
    required this.targets,
    required this.draft,
    required this.selectedAgentIds,
    required this.onDraftChanged,
    this.agentCardWidth = 220,
    this.modelCardWidth = 320,
    this.settingsCardWidth = 200,
    this.revealSelectionOnOpen = false,
    this.isRefreshingAgentCatalog,
    this.onAgentCatalogRequested,
  });

  final String keyPrefix;
  final bool showFast;
  final BorderRadius borderRadius;
  final double maxHeight;
  final List<TargetCandidate> targets;
  final DailyConversationAgentAssignment draft;
  final Set<String> selectedAgentIds;
  final ValueChanged<DailyConversationAgentAssignment> onDraftChanged;
  final double agentCardWidth;
  final double modelCardWidth;
  final double settingsCardWidth;

  /// When true, each column scrolls the persisted selection into view the
  /// first time it appears, so an existing configuration is visible on open.
  final bool revealSelectionOnOpen;
  final bool Function(String agentId)? isRefreshingAgentCatalog;
  final ValueChanged<String>? onAgentCatalogRequested;

  @override
  State<AgentRuntimeAssignmentCascadeCards> createState() =>
      _AgentRuntimeAssignmentCascadeCardsState();
}

final class _AgentRuntimeAssignmentCascadeCardsState
    extends State<AgentRuntimeAssignmentCascadeCards> {
  static const double _rowExtent = 32;
  static const Duration _dismissGrace = LicoMotion.short;

  String? _previewAgentId;
  String? _hoveredModel;
  Timer? _dismissTimer;
  final TextEditingController _modelQueryController = TextEditingController();
  String _modelQuery = '';
  final Map<String, GlobalKey> _revealKeys = <String, GlobalKey>{};
  final Set<String> _pendingReveal = <String>{'agent', 'model', 'effort'};
  bool _revealScheduled = false;

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _modelQueryController.dispose();
    super.dispose();
  }

  String? get _activeAgentId {
    final draftId = widget.draft.agentId.trim();
    if (draftId.isNotEmpty &&
        widget.targets.any((target) => target.target == draftId)) {
      return draftId;
    }
    if (_previewAgentId != null &&
        widget.targets.any((target) => target.target == _previewAgentId)) {
      return _previewAgentId;
    }
    return widget.targets.isEmpty ? null : widget.targets.first.target;
  }

  void _onAgentEnter(String agentId) {
    _dismissTimer?.cancel();
    widget.onAgentCatalogRequested?.call(agentId);
    setState(() {
      _previewAgentId = agentId;
      _hoveredModel = null;
      _clearModelQuery();
    });
  }

  /// The model filter belongs to one agent's list; switching agents resets it.
  void _clearModelQuery() {
    if (_modelQuery.isEmpty && _modelQueryController.text.isEmpty) return;
    _modelQueryController.clear();
    _modelQuery = '';
  }

  void _onCascadeExit() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(_dismissGrace, () {
      if (!mounted) return;
      setState(() {
        _previewAgentId = null;
        _hoveredModel = null;
      });
    });
  }

  TargetCandidate? get _activeTarget {
    final id = _activeAgentId;
    if (id == null) return null;
    for (final target in widget.targets) {
      if (target.target == id) return target;
    }
    return null;
  }

  List<String> _modelsFor(TargetCandidate target) =>
      agentOrchestrationCommanderModels(target);

  DailyConversationAgentAssignment _draftSeed(TargetCandidate target) {
    return DailyConversationAgentAssignment(agentId: target.target);
  }

  String _effectiveModel(TargetCandidate target) {
    final models = _modelsFor(target);
    if (models.isEmpty) return '';
    // A confirmed model (persisted or tapped) owns the reasoning-effort card;
    // hovering other models must not re-point it. Hover previews efforts only
    // while no model has been confirmed for the active agent yet.
    if (widget.draft.agentId == target.target) {
      final selected = widget.draft.modelName.trim();
      if (models.contains(selected)) return selected;
    }
    if (_hoveredModel != null && models.contains(_hoveredModel)) {
      return _hoveredModel!;
    }
    return models.first;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final active = _activeTarget;
    final modelGroups = active == null
        ? const <AgentOrchestrationModelGroup>[]
        : agentOrchestrationCommanderModelGroups(active);
    final models = [for (final group in modelGroups) ...group.models];
    final showProviderHeaders = modelGroups.any(
      (group) => group.providerLabel.isNotEmpty,
    );
    final refreshing =
        active != null &&
        widget.isRefreshingAgentCatalog?.call(active.target) == true;
    final effectiveModel = active == null ? '' : _effectiveModel(active);
    final efforts = active == null || effectiveModel.isEmpty
        ? const <String>[]
        : agentOrchestrationReasoningEffortsForModel(active, effectiveModel);
    final draftForActive = active == null
        ? const DailyConversationAgentAssignment()
        : (widget.draft.agentId == active.target
              ? widget.draft
              : _draftSeed(active));
    final gap = MessagingDesktopMetrics.composerRuntimeSelectorSubmenuGap;
    final modelQuery = _modelQuery.trim().toLowerCase();

    bool modelMatchesQuery(String model) {
      if (modelQuery.isEmpty) return true;
      if (model.toLowerCase().contains(modelQuery)) return true;
      final display = active == null
          ? ''
          : agentOrchestrationModelDisplayName(active, model).toLowerCase();
      return display.contains(modelQuery);
    }

    final visibleGroups = <AgentOrchestrationModelGroup>[
      for (final group in modelGroups)
        if (group.models.any(modelMatchesQuery))
          AgentOrchestrationModelGroup(
            providerId: group.providerId,
            providerLabel: group.providerLabel,
            models: List.unmodifiable(group.models.where(modelMatchesQuery)),
          ),
    ];
    final visibleModels = [for (final group in visibleGroups) ...group.models];

    Widget sectionHeader(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Text(
        label,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 14 / 11,
        ),
      ),
    );

    Widget glassCard({
      required Key key,
      required double width,
      Widget? header,
      required List<Widget> children,
      List<Widget> pinned = const <Widget>[],
    }) {
      final Widget body = pinned.isEmpty
          ? SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [?header, ...children, const SizedBox(height: 6)],
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?header,
                ...pinned,
                // SingleChildScrollView hugs short lists and caps long ones at
                // the Flexible bound, and its Column builds every child so the
                // reveal anchor exists even while it is scrolled off screen.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...children, const SizedBox(height: 6)],
                    ),
                  ),
                ),
              ],
            );
      return MessagingConversationOverlayGlass(
        key: key,
        borderRadius: widget.borderRadius,
        readabilityVeil: true,
        child: SizedBox(
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: body,
          ),
        ),
      );
    }

    final agentRows = <Widget>[];
    var agentRevealAssigned = false;
    for (final target in widget.targets) {
      final selected = widget.selectedAgentIds.contains(target.target);
      var reveal = false;
      if (widget.revealSelectionOnOpen && selected && !agentRevealAssigned) {
        agentRevealAssigned = true;
        reveal = true;
      }
      agentRows.add(_agentRow(target, selected: selected, reveal: reveal));
    }

    final modelRows = <Widget>[];
    if (active != null) {
      for (final group in visibleGroups) {
        if (showProviderHeaders && group.providerLabel.isNotEmpty) {
          modelRows.add(
            Padding(
              key: Key(
                '${widget.keyPrefix}-provider-${active.target}-${group.providerId.isNotEmpty ? group.providerId : group.providerLabel}',
              ),
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 3),
              child: Text(
                group.providerLabel,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 14 / 11,
                ),
              ),
            ),
          );
        }
        for (final model in group.models) {
          modelRows.add(_modelRow(active, model, draftForActive));
        }
      }
    }

    _scheduleRevealIfNeeded();

    return MouseRegion(
      key: Key('${widget.keyPrefix}-options'),
      onExit: (_) => _onCascadeExit(),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            glassCard(
              key: Key('${widget.keyPrefix}-agent-card'),
              width: widget.agentCardWidth,
              header: sectionHeader(strings.agent),
              children: [
                if (widget.targets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                    child: Text(
                      strings.noAgentsFound,
                      style: TextStyle(color: colors.textMuted, fontSize: 12.5),
                    ),
                  )
                else
                  ...agentRows,
              ],
            ),
            if (active != null) ...[
              SizedBox(width: gap),
              glassCard(
                key: Key('${widget.keyPrefix}-model-card'),
                width: widget.modelCardWidth,
                // No section title: the pinned search field is the header.
                pinned: [
                  _modelSearchField(colors, strings),
                  if (refreshing)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: LinearProgressIndicator(
                        key: Key('${widget.keyPrefix}-model-loading'),
                        minHeight: 2,
                      ),
                    ),
                ],
                children: [
                  if (models.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                      child: Text(
                        refreshing
                            ? strings.discoveringModels
                            : strings.noModelsFound,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    )
                  else if (visibleModels.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                      child: Text(
                        strings.noModelsFound,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    )
                  else
                    ...modelRows,
                ],
              ),
              if (efforts.isNotEmpty || widget.showFast) ...[
                SizedBox(width: gap),
                glassCard(
                  key: Key('${widget.keyPrefix}-settings-card'),
                  width: widget.settingsCardWidth,
                  header: sectionHeader(strings.reasoningEffort),
                  children: [
                    for (final effort in efforts)
                      _effortRow(
                        active,
                        effort,
                        draftForActive,
                        effectiveModel,
                      ),
                    if (widget.showFast)
                      _FastSwitchRow(
                        keyPrefix: widget.keyPrefix,
                        enabled: draftForActive.fast,
                        onChanged: (fast) {
                          widget.onDraftChanged(
                            draftForActive.copyWith(
                              agentId: active.target,
                              modelName: draftForActive.modelName.isEmpty
                                  ? effectiveModel
                                  : draftForActive.modelName,
                              fast: fast,
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _agentRow(
    TargetCandidate target, {
    required bool selected,
    required bool reveal,
  }) {
    final row = _CascadeAgentRow(
      optionKey: Key('${widget.keyPrefix}-option-${target.target}'),
      target: target,
      selected: selected,
      active: target.target == _activeAgentId,
      hasModels: _modelsFor(target).isNotEmpty,
      rowExtent: _rowExtent,
      onEnter: () => _onAgentEnter(target.target),
      onTap: () {
        widget.onAgentCatalogRequested?.call(target.target);
        setState(_clearModelQuery);
        widget.onDraftChanged(_draftSeed(target));
      },
    );
    if (!reveal) return row;
    return KeyedSubtree(key: _revealKey('agent'), child: row);
  }

  Widget _modelRow(
    TargetCandidate active,
    String model,
    DailyConversationAgentAssignment draftForActive,
  ) {
    final row = _CascadeOptionRow(
      key: Key('${widget.keyPrefix}-model-${active.target}-$model'),
      label: agentOrchestrationModelDisplayName(active, model),
      selected: model == draftForActive.modelName,
      wrapLabel: true,
      onEnter: () {
        _dismissTimer?.cancel();
        setState(() => _hoveredModel = model);
      },
      onTap: () {
        widget.onDraftChanged(
          draftForActive.copyWith(
            agentId: active.target,
            modelName: model,
            reasoningEffort: '',
          ),
        );
      },
    );
    if (widget.revealSelectionOnOpen && model == draftForActive.modelName) {
      return KeyedSubtree(key: _revealKey('model'), child: row);
    }
    return row;
  }

  Widget _effortRow(
    TargetCandidate active,
    String effort,
    DailyConversationAgentAssignment draftForActive,
    String effectiveModel,
  ) {
    final strings = LicoStrings.of(context);
    final row = _CascadeOptionRow(
      key: Key('${widget.keyPrefix}-effort-${active.target}-$effort'),
      label: strings.reasoningEffortOptionLabel(effort, effort),
      selected: effort == draftForActive.reasoningEffort,
      onEnter: () => _dismissTimer?.cancel(),
      onTap: () {
        widget.onDraftChanged(
          draftForActive.copyWith(
            agentId: active.target,
            modelName: draftForActive.modelName.isEmpty
                ? effectiveModel
                : draftForActive.modelName,
            reasoningEffort: effort,
          ),
        );
      },
    );
    if (widget.revealSelectionOnOpen &&
        effort == draftForActive.reasoningEffort) {
      return KeyedSubtree(key: _revealKey('effort'), child: row);
    }
    return row;
  }

  static const InputDecoration _modelSearchDecoration = InputDecoration(
    isDense: true,
    isCollapsed: true,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    contentPadding: EdgeInsets.zero,
  );

  Widget _modelSearchField(LicoThemeColors colors, LicoStrings strings) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
      child: SizedBox(
        height: 30,
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 15,
              color: colors.textMuted.withAlpha(200),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                key: Key('${widget.keyPrefix}-model-search'),
                controller: _modelQueryController,
                cursorColor: colors.accent,
                cursorWidth: 1.5,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                ),
                strutStyle: const StrutStyle(
                  fontSize: 12.5,
                  height: 1.0,
                  forceStrutHeight: true,
                ),
                decoration: _modelSearchDecoration.copyWith(
                  hintText: strings.modelSearchHint,
                  hintStyle: TextStyle(
                    color: MessagingDesktopMetrics.chromeSearchPlaceholder(),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                  ),
                ),
                onChanged: (value) => setState(() => _modelQuery = value),
              ),
            ),
            if (_modelQuery.trim().isNotEmpty)
              InkWell(
                key: Key('${widget.keyPrefix}-model-search-clear'),
                customBorder: const CircleBorder(),
                onTap: () => setState(_clearModelQuery),
                child: SizedBox.square(
                  dimension: 24,
                  child: Icon(
                    Icons.close_rounded,
                    size: 13,
                    color: colors.textMuted.withAlpha(200),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  GlobalKey _revealKey(String column) {
    return _revealKeys.putIfAbsent(
      column,
      () => GlobalKey(debugLabel: '${widget.keyPrefix}-reveal-$column'),
    );
  }

  /// Reveal the persisted selection once per column; a late model catalog
  /// simply delays that column's scroll until its rows exist.
  void _scheduleRevealIfNeeded() {
    if (!widget.revealSelectionOnOpen ||
        _pendingReveal.isEmpty ||
        _revealScheduled) {
      return;
    }
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !widget.revealSelectionOnOpen) return;
      for (final column in List<String>.of(_pendingReveal)) {
        final rowContext = _revealKeys[column]?.currentContext;
        if (rowContext == null) continue;
        _pendingReveal.remove(column);
        Scrollable.ensureVisible(
          rowContext,
          alignment: 0.5,
          duration: LicoMotion.medium,
          curve: LicoMotion.decelerate,
        );
      }
    });
  }
}

final class _CascadeAgentRow extends StatelessWidget {
  const _CascadeAgentRow({
    required this.optionKey,
    required this.target,
    required this.selected,
    required this.active,
    required this.hasModels,
    required this.rowExtent,
    required this.onEnter,
    required this.onTap,
  });

  final Key optionKey;
  final TargetCandidate target;
  final bool selected;
  final bool active;
  final bool hasModels;
  final double rowExtent;
  final VoidCallback onEnter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return MouseRegion(
      onEnter: (_) => onEnter(),
      child: Material(
        color: active
            ? ConversationVisualTokens.selectedOptionFill(colors)
            : Colors.transparent,
        child: InkWell(
          key: optionKey,
          onTap: onTap,
          child: SizedBox(
            height: rowExtent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  AgentBrandIcon(target: target, size: 16, iconSize: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      agentConversationTargetDisplayName(target),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 12.5,
                        fontWeight: selected || active
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check_rounded, size: 15, color: colors.accent)
                  else if (hasModels)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: colors.textMuted.withAlpha(160),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CascadeOptionRow extends StatelessWidget {
  const _CascadeOptionRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onEnter,
    required this.onTap,
    this.wrapLabel = false,
  });

  final String label;
  final bool selected;
  final bool wrapLabel;
  final VoidCallback onEnter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return MouseRegion(
      onEnter: (_) => onEnter(),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: wrapLabel ? 8 : 0,
          ),
          child: SizedBox(
            height: wrapLabel ? null : 32,
            child: Row(
              crossAxisAlignment: wrapLabel
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: wrapLabel ? 4 : 1,
                    softWrap: wrapLabel,
                    overflow: wrapLabel
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_rounded, size: 15, color: colors.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _FastSwitchRow extends StatelessWidget {
  const _FastSwitchRow({
    required this.keyPrefix,
    required this.enabled,
    required this.onChanged,
  });

  final String keyPrefix;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              strings.fastModeLabel,
              style: TextStyle(
                color: colors.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Transform.scale(
            scale: 0.78,
            child: Switch.adaptive(
              key: Key('$keyPrefix-fast-switch'),
              value: enabled,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

final class _SearchStyleCapsule extends StatelessWidget {
  const _SearchStyleCapsule({required this.focused, required this.child});

  final bool focused;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return AppleGlassSurface(
      borderRadius: kComposerCapsuleBorderRadius,
      fillAlpha: colors.isDark ? 22 : 10,
      focused: focused,
      focusColor: colors.primaryStrong,
      focusedBorderWidth: AppleControlMetrics.searchFocusRingWidth,
      child: child,
    );
  }
}

final class _CapsuleSearchField extends StatelessWidget {
  const _CapsuleSearchField({
    required this.keyPrefix,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.selectedTarget,
    required this.readOnly,
    required this.onClose,
    required this.onSubmitted,
  });

  final String keyPrefix;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final TargetCandidate? selectedTarget;
  final bool readOnly;
  final VoidCallback onClose;
  final ValueChanged<String> onSubmitted;

  static const InputDecoration _borderless = InputDecoration(
    isDense: true,
    isCollapsed: true,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    contentPadding: EdgeInsets.zero,
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Theme(
      data: Theme.of(context).copyWith(
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        inputDecorationTheme: const InputDecorationTheme(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          filled: false,
          isDense: true,
          isCollapsed: true,
          contentPadding: EdgeInsets.zero,
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          if (selectedTarget case final target?) ...[
            AgentBrandIcon(target: target, size: 14, iconSize: 14),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: TextField(
              key: Key('$keyPrefix-input'),
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              readOnly: readOnly,
              cursorColor: colors.accent,
              cursorWidth: 1.5,
              style: TextStyle(
                color: colors.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                height: 1.0,
              ),
              strutStyle: const StrutStyle(
                fontSize: 12.5,
                height: 1.0,
                forceStrutHeight: true,
              ),
              decoration: _borderless.copyWith(
                hintText: readOnly ? null : hintText,
                hintStyle: TextStyle(
                  color: MessagingDesktopMetrics.chromeSearchPlaceholder(),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                ),
              ),
              onSubmitted: readOnly ? null : onSubmitted,
            ),
          ),
          Tooltip(
            message: strings.close,
            waitDuration: LicoMotion.tooltipWait,
            child: InkWell(
              key: Key('$keyPrefix-collapse'),
              customBorder: const CircleBorder(),
              onTap: onClose,
              child: SizedBox.square(
                dimension: 28,
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: colors.textMuted.withAlpha(200),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _SelectedAgentCapsule extends StatelessWidget {
  const _SelectedAgentCapsule({
    required this.keyPrefix,
    required this.assignment,
    required this.target,
    required this.onRemove,
    this.isCurrentConversation = false,
  });

  final String keyPrefix;
  final DailyConversationAgentAssignment assignment;
  final TargetCandidate? target;
  final VoidCallback onRemove;
  final bool isCurrentConversation;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final agentLabel = target == null
        ? assignment.agentId
        : agentConversationTargetDisplayName(target!);
    final label = composeOrchestrationAssignmentCapsuleLabel(
      agentLabel: agentLabel,
      modelName: assignment.modelName,
      reasoningEffort: assignment.reasoningEffort,
      fast: assignment.fast,
      fastLabel: strings.fastModeLabel,
      effortLabel: (effort) =>
          strings.reasoningEffortOptionLabel(effort, effort),
      modelDisplayName: target == null
          ? null
          : (model) => agentOrchestrationModelDisplayName(target!, model),
    );
    final chipKey = assignment.id.trim().isEmpty
        ? assignment.agentId
        : assignment.id;
    final chip = AppleGlassSurface(
      key: Key(
        isCurrentConversation
            ? '$keyPrefix-chip-current-$chipKey'
            : '$keyPrefix-chip-$chipKey',
      ),
      borderRadius: kComposerCapsuleBorderRadius,
      fillAlpha: colors.isDark ? 18 : 10,
      // Accent ring marks the Daily Conversation head as Current Conversation
      // — the plain-send dispatch owner.
      focused: isCurrentConversation,
      focusColor: colors.accent,
      focusedBorderWidth: isCurrentConversation ? 1.25 : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (target case final target?)
              AgentBrandIcon(target: target, size: 14, iconSize: 14)
            else
              Icon(Icons.smart_toy_outlined, size: 14, color: colors.textMuted),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              key: Key('$keyPrefix-chip-remove-$chipKey'),
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: SizedBox.square(
                dimension: 22,
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: colors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!isCurrentConversation) {
      return chip;
    }
    return Tooltip(
      message: strings.currentConversation,
      waitDuration: const Duration(milliseconds: 400),
      child: chip,
    );
  }
}
