import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class SecureMeshCapabilityCard extends StatefulWidget {
  const SecureMeshCapabilityCard({super.key, required this.projection});

  final SecureMeshCapabilityProjection projection;

  @override
  State<SecureMeshCapabilityCard> createState() =>
      _SecureMeshCapabilityCardState();
}

class _SecureMeshCapabilityCardState extends State<SecureMeshCapabilityCard> {
  final FocusNode _headerFocusNode = FocusNode(
    debugLabel: 'secure-mesh-capability-header',
  );
  bool _expanded = false;
  bool _focused = false;

  @override
  void dispose() {
    _headerFocusNode.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final motionDisabled = MediaQuery.disableAnimationsOf(context);
    final containerDuration = motionDisabled
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final sizeDuration = motionDisabled
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final actionHint = _expanded
        ? strings.collapseSecurityCapabilities
        : strings.expandSecurityCapabilities;
    // Neutral charcoal, deliberately not the brand-tinted surface.
    final cardFill = colors.surfaceLow;

    return AnimatedContainer(
      key: const Key('secure-mesh-capability-card'),
      duration: containerDuration,
      curve: Curves.easeOutCubic,
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardFill,
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        border: Border.all(
          color: _focused ? colors.primary : colors.line,
          width: _focused ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              key: const Key('secure-mesh-capability-semantics'),
              container: true,
              button: true,
              focusable: true,
              focused: _focused,
              expanded: _expanded,
              label: strings.securityCapabilities,
              hint: actionHint,
              onTap: _toggleExpanded,
              child: ExcludeSemantics(
                child: Tooltip(
                  message: actionHint,
                  child: InkWell(
                    key: const Key('secure-mesh-capability-toggle'),
                    focusNode: _headerFocusNode,
                    onFocusChange: (focused) {
                      if (_focused != focused) {
                        setState(() => _focused = focused);
                      }
                    },
                    onTap: _toggleExpanded,
                    focusColor: colors.primary.withValues(alpha: 0.10),
                    hoverColor: colors.text.withValues(alpha: 0.04),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.security_outlined,
                              color: colors.textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                strings.securityCapabilities,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            const SizedBox(width: 8),
                            AnimatedRotation(
                              turns: _expanded ? 0.5 : 0,
                              duration: containerDuration,
                              curve: Curves.easeOutCubic,
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 20,
                                color: colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (motionDisabled)
              _expanded
                  ? _CapabilityDetails(projection: widget.projection)
                  : const SizedBox.shrink()
            else
              AnimatedSize(
                duration: sizeDuration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? _CapabilityDetails(projection: widget.projection)
                    : const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }
}

class _CapabilityDetails extends StatelessWidget {
  const _CapabilityDetails({required this.projection});

  final SecureMeshCapabilityProjection projection;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Padding(
      key: const Key('secure-mesh-capability-details'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CapabilitySetView(
            keyPrefix: 'secure-mesh-local',
            title: strings.localEndpointCapabilities,
            projection: projection.local,
          ),
          const SizedBox(height: 14),
          if (projection.peer != null)
            _CapabilitySetView(
              keyPrefix: 'secure-mesh-peer',
              title: strings.peerEndpointCapabilities,
              projection: projection.peer!,
            )
          else
            _ReasonView(
              key: const Key('secure-mesh-peer-reason'),
              title: strings.peerEndpointCapabilities,
              reasons: {
                'peer':
                    projection.reasons['peer'] ??
                    'secure_mesh_peer_capability_proof_not_available',
              },
            ),
          const SizedBox(height: 14),
          _CapabilityValues(
            key: const Key('secure-mesh-negotiated-protocol-capabilities'),
            label: strings.negotiatedProtocolCapabilities,
            values: projection.negotiatedProtocolCapabilities,
          ),
          if (projection.reasons.isNotEmpty) ...[
            const SizedBox(height: 10),
            _ReasonView(
              key: const Key('secure-mesh-session-capability-reasons'),
              title: strings.capabilityReasons,
              reasons: projection.reasons,
            ),
          ],
        ],
      ),
    );
  }
}

class _CapabilitySetView extends StatelessWidget {
  const _CapabilitySetView({
    required this.keyPrefix,
    required this.title,
    required this.projection,
  });

  final String keyPrefix;
  final String title;
  final SecureMeshCapabilitySetProjection projection;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-selected-custody'),
          label: strings.selectedCustody,
          values: [projection.selectedCustody.strategy],
        ),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-restart-semantics'),
          label: strings.custodyRestartSemantics,
          values: [projection.selectedCustody.restartSemantics],
        ),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-enabled-hardening'),
          label: strings.enabledCustodyHardening,
          values: projection.selectedCustody.enabledHardening,
        ),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-dependencies'),
          label: strings.capabilityDependencies,
          values: projection.dependencies
              .map(
                (dependency) =>
                    '${dependency.capability} ← ${dependency.prerequisites.join(', ')}',
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-enabled'),
          label: strings.enabledCapabilities,
          values: projection.enabled,
        ),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-available'),
          label: strings.availableCapabilities,
          values: projection.available,
        ),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-unavailable'),
          label: strings.unavailableCapabilities,
          values: projection.unavailable,
        ),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-unverified'),
          label: strings.unverifiedCapabilities,
          values: projection.unverified,
        ),
        const SizedBox(height: 8),
        _CapabilityValues(
          key: Key('$keyPrefix-missing-mandatory'),
          label: strings.missingMandatoryCapabilities,
          values: projection.missingMandatory,
        ),
        if (projection.reasons.isNotEmpty) ...[
          const SizedBox(height: 8),
          _ReasonView(
            key: Key('$keyPrefix-reasons'),
            title: strings.capabilityReasons,
            reasons: projection.reasons,
          ),
        ],
      ],
    );
  }
}

class _CapabilityValues extends StatelessWidget {
  const _CapabilityValues({
    super.key,
    required this.label,
    required this.values,
  });

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: colors.textMuted)),
        const SizedBox(height: 3),
        SelectableText(
          values.isEmpty ? strings.noCapabilities : values.join('\n'),
          style: TextStyle(
            color: colors.text,
            fontFamily: 'monospace',
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _ReasonView extends StatelessWidget {
  const _ReasonView({super.key, required this.title, required this.reasons});

  final String title;
  final Map<String, String> reasons;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(color: colors.textMuted)),
        const SizedBox(height: 3),
        SelectableText(
          reasons.entries
              .map((entry) => '${entry.key} · ${entry.value}')
              .join('\n'),
          style: TextStyle(
            color: colors.text,
            fontFamily: 'monospace',
            height: 1.35,
          ),
        ),
      ],
    );
  }
}
