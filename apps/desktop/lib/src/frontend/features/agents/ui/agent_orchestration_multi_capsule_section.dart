import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_target_catalog.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Reusable Adaptive Flywheel multi-capsule picker.
///
/// Title sits outside, above a stadium (full-pill) shell that matches the
/// inner assignment capsules. Collapsed: circular plus. Expanded: the shell
/// stays a single row (chips + draft field + confirm); agent / model /
/// reasoning cards float via [OverlayPortal.targetsRootOverlay] (flip above
/// when space below is tight) and do not resize the stadium. The draft field
/// mirrors cascade picks: agent icon and `Agent · Model · Effort`.
final class AgentOrchestrationMultiCapsuleSection extends StatefulWidget {
  const AgentOrchestrationMultiCapsuleSection({
    super.key,
    required this.title,
    required this.keyPrefix,
    required this.idPrefix,
    required this.assignments,
    required this.targets,
    required this.onChanged,
    this.showFast = false,
    this.description = '',
  });

  final String title;
  final String description;
  final String keyPrefix;
  final String idPrefix;
  final bool showFast;
  final List<DailyConversationAgentAssignment> assignments;
  final List<TargetCandidate> targets;
  final ValueChanged<List<DailyConversationAgentAssignment>> onChanged;

  @override
  State<AgentOrchestrationMultiCapsuleSection> createState() =>
      _AgentOrchestrationMultiCapsuleSectionState();
}

final class _AgentOrchestrationMultiCapsuleSectionState
    extends State<AgentOrchestrationMultiCapsuleSection> {
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
      return (
        openUpward: false,
        maxCardHeight: _cascadePreferredHeight,
      );
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

    // Root overlay paints above the dialog footer so Reviewer/Worker cards
    // are not covered by Cancel/Save. Flip upward when space below is tight.
    return OverlayPortal.targetsRootOverlay(
      controller: _cascadePortalController,
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
              child: _DailyConversationCascadeCards(
                keyPrefix: widget.keyPrefix,
                showFast: widget.showFast,
                borderRadius: menuRadius,
                maxHeight: placement.maxCardHeight,
                targets: filtered,
                draft: _draft,
                selectedAgentIds: selectedIds,
                onDraftChanged: _setDraft,
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
                  Colors.black.withAlpha(colors.isDark ? 110 : 36),
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
                                          readOnly:
                                              _draft.agentId.trim().isNotEmpty,
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
                                          message: strings
                                              .addDailyConversationAgent,
                                          waitDuration: LicoMotion.tooltipWait,
                                          child: InkWell(
                                            key: Key(
                                              '${widget.keyPrefix}-add',
                                            ),
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
                            message:
                                strings.confirmDailyConversationSelection,
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

final class _DailyConversationCascadeCards extends StatefulWidget {
  const _DailyConversationCascadeCards({
    required this.keyPrefix,
    required this.showFast,
    required this.borderRadius,
    required this.maxHeight,
    required this.targets,
    required this.draft,
    required this.selectedAgentIds,
    required this.onDraftChanged,
  });

  final String keyPrefix;
  final bool showFast;
  final BorderRadius borderRadius;
  final double maxHeight;
  final List<TargetCandidate> targets;
  final DailyConversationAgentAssignment draft;
  final Set<String> selectedAgentIds;
  final ValueChanged<DailyConversationAgentAssignment> onDraftChanged;

  @override
  State<_DailyConversationCascadeCards> createState() =>
      _DailyConversationCascadeCardsState();
}

final class _DailyConversationCascadeCardsState
    extends State<_DailyConversationCascadeCards> {
  static const double _rowExtent = 32;
  static const double _agentCardWidth = 220;
  static const double _modelCardWidth = 200;
  static const double _settingsCardWidth = 200;
  static const Duration _dismissGrace = Duration(milliseconds: 180);

  String? _previewAgentId;
  String? _hoveredModel;
  Timer? _dismissTimer;

  @override
  void dispose() {
    _dismissTimer?.cancel();
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
    setState(() {
      _previewAgentId = agentId;
      _hoveredModel = null;
    });
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
    if (_hoveredModel != null && models.contains(_hoveredModel)) {
      return _hoveredModel!;
    }
    if (widget.draft.agentId == target.target) {
      final selected = widget.draft.modelName.trim();
      if (models.contains(selected)) return selected;
    }
    return models.first;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final active = _activeTarget;
    final models = active == null ? const <String>[] : _modelsFor(active);
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
      required Widget header,
      required List<Widget> children,
    }) {
      return MessagingConversationOverlayGlass(
        key: key,
        borderRadius: widget.borderRadius,
        readabilityVeil: true,
        child: SizedBox(
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [header, ...children, const SizedBox(height: 6)],
              ),
            ),
          ),
        ),
      );
    }

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
              width: _agentCardWidth,
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
                  for (final target in widget.targets)
                    _CascadeAgentRow(
                      optionKey: Key(
                        '${widget.keyPrefix}-option-${target.target}',
                      ),
                      target: target,
                      selected: widget.selectedAgentIds.contains(target.target),
                      active: target.target == _activeAgentId,
                      hasModels: _modelsFor(target).isNotEmpty,
                      rowExtent: _rowExtent,
                      onEnter: () => _onAgentEnter(target.target),
                      onTap: () => widget.onDraftChanged(_draftSeed(target)),
                    ),
              ],
            ),
            if (active != null) ...[
              SizedBox(width: gap),
              glassCard(
                key: Key('${widget.keyPrefix}-model-card'),
                width: _modelCardWidth,
                header: sectionHeader(strings.model),
                children: [
                  if (models.isEmpty)
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
                    for (final model in models)
                      _CascadeOptionRow(
                        key: Key('${widget.keyPrefix}-model-${active.target}-$model'),
                        label: agentOrchestrationModelDisplayName(
                          active,
                          model,
                        ),
                        selected: model == draftForActive.modelName,
                        rowExtent: _rowExtent,
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
                      ),
                ],
              ),
              SizedBox(width: gap),
              glassCard(
                key: Key('${widget.keyPrefix}-settings-card'),
                width: _settingsCardWidth,
                header: sectionHeader(strings.reasoningEffort),
                children: [
                  if (efforts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Text(
                        strings.noReasoningEffortsFound,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    )
                  else
                    for (final effort in efforts)
                      _CascadeOptionRow(
                        key: Key('${widget.keyPrefix}-effort-${active.target}-$effort'),
                        label: strings.reasoningEffortOptionLabel(
                          effort,
                          effort,
                        ),
                        selected: effort == draftForActive.reasoningEffort,
                        rowExtent: _rowExtent,
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
        ),
      ),
    );
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
            ? (colors.isDark
                  ? Colors.white.withAlpha(10)
                  : Colors.black.withAlpha(8))
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
    required this.rowExtent,
    required this.onEnter,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final double rowExtent;
  final VoidCallback onEnter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return MouseRegion(
      onEnter: (_) => onEnter(),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: rowExtent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
              key: Key('${keyPrefix}-fast-switch'),
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
  });

  final String keyPrefix;
  final DailyConversationAgentAssignment assignment;
  final TargetCandidate? target;
  final VoidCallback onRemove;

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
    return AppleGlassSurface(
      key: Key('$keyPrefix-chip-$chipKey'),
      borderRadius: kComposerCapsuleBorderRadius,
      fillAlpha: colors.isDark ? 18 : 10,
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
  }
}
