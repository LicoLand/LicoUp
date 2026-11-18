import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/devices/ui/devices_cards.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/devices/devices_binding.dart';
import 'package:licoup/src/presentation/devices/devices_effect.dart';
import 'package:licoup/src/presentation/devices/devices_intent.dart';
import 'package:licoup/src/presentation/devices/devices_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// The Devices surface: join a LicoArc station, pair with another desktop,
/// manage paired devices, and send an agent message to a paired device.
class DevicesPanel extends StatefulWidget {
  const DevicesPanel({super.key, required this.binding});

  final DevicesBinding binding;

  @override
  State<DevicesPanel> createState() => _DevicesPanelState();
}

class _DevicesPanelState extends State<DevicesPanel> {
  String _selectedPeerId = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.binding.projection.current.phase == PresentationPhase.idle) {
        widget.binding.intents.send(const RefreshDevices());
      }
    }, debugLabel: 'DevicesPanel.initialRefresh');
  }

  @override
  Widget build(BuildContext context) {
    return EffectListener<DevicesEffect>(
      source: widget.binding.effects,
      onEffect: _onEffect,
      child: ProjectionBuilder<DevicesProjection, DevicesProjection>(
        source: widget.binding.projection,
        select: (projection) => projection,
        builder: _buildPanel,
      ),
    );
  }

  Widget _buildPanel(BuildContext context, DevicesProjection projection) {
    final strings = LicoStrings.of(context);
    final intents = widget.binding.intents;
    final busy =
        projection.busy || projection.phase == PresentationPhase.loading;
    final selectedPeer = _selectedPeer(projection);
    return LicoPaneScaffold(
      title: strings.devices,
      refreshTooltip: strings.refresh,
      onRefresh: busy ? null : () => intents.send(const RefreshDevices()),
      refreshing: busy,
      refreshButtonKey: const Key('devices-refresh'),
      body: ListView(
        key: const Key('devices-panel'),
        padding: EdgeInsets.zero,
        children: [
          if (projection.showLegacyPairingNotice) ...[
            DevicesLegacyPairingNotice(intents: intents),
            const SizedBox(height: 12),
          ],
          if (projection.errorCode.isNotEmpty) ...[
            _DevicesFailureLine(code: projection.errorCode),
            const SizedBox(height: 12),
          ],
          if (projection.phase == PresentationPhase.idle ||
              projection.phase == PresentationPhase.loading)
            const SizedBox.shrink()
          else if (!projection.enrolled)
            DevicesEnrollCard(busy: busy, intents: intents)
          else ...[
            DevicesStationCard(projection: projection),
            const SizedBox(height: 12),
            DevicesPairingCard(
              projection: projection,
              busy: busy,
              intents: intents,
            ),
            const SizedBox(height: 12),
            DevicesPeersCard(
              projection: projection,
              selectedPeerId: selectedPeer?.peerId ?? '',
              busy: busy,
              intents: intents,
              onSelect: (peerId) => setState(() => _selectedPeerId = peerId),
            ),
            if (selectedPeer != null) ...[
              const SizedBox(height: 12),
              DevicesMessageCard(
                key: ValueKey('devices-message-${selectedPeer.peerId}'),
                peer: selectedPeer,
                projection: projection,
                busy: busy,
                intents: intents,
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// The chosen peer, or the first peer while none is chosen; a peer that
  /// was unpaired is no longer chosen.
  DevicePeerView? _selectedPeer(DevicesProjection projection) {
    for (final peer in projection.peers) {
      if (peer.peerId == _selectedPeerId) return peer;
    }
    return projection.peers.isEmpty ? null : projection.peers.first;
  }

  void _onEffect(DevicesEffect effect) {
    if (!mounted) return;
    final strings = LicoStrings.of(context);
    final (message, kind) = switch (effect) {
      DevicesActionCompleted(:final action) => (
        switch (action) {
          DevicesAction.enrolled => strings.devicesEnrolled,
          DevicesAction.pairingCodeCopied => strings.devicesPairingCodeCopied,
          DevicesAction.pairingClaimed => strings.devicesPairingClaimed,
          DevicesAction.pairingCancelled => strings.devicesPairingCancelled,
          DevicesAction.unpaired => strings.devicesUnpaired,
          DevicesAction.messageSent => strings.devicesMessageSent,
        },
        LicoToastKind.success,
      ),
      DevicesActionRejected(:final reasonCode) => (
        strings.devicesFailure(reasonCode),
        LicoToastKind.error,
      ),
    };
    showLicoToast(context, message: message, kind: kind);
  }
}

class _DevicesFailureLine extends StatelessWidget {
  const _DevicesFailureLine({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Row(
      key: const Key('devices-failure'),
      children: [
        Icon(Icons.error_outline, size: 18, color: colors.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            LicoStrings.of(context).devicesFailure(code),
            style: TextStyle(color: colors.error),
          ),
        ),
      ],
    );
  }
}
