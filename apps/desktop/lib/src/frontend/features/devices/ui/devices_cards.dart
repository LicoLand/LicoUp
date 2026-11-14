import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/endpoint_configuration.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/devices/devices_intent.dart';
import 'package:licoup/src/presentation/devices/devices_projection.dart';

/// One-time notice: pre-0.3.0 pairings are not carried over.
class DevicesLegacyPairingNotice extends StatelessWidget {
  const DevicesLegacyPairingNotice({super.key, required this.intents});

  final IntentSink<DevicesIntent> intents;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return Card(
      key: const Key('devices-legacy-notice'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: colors.accent),
            const SizedBox(width: 12),
            Expanded(child: Text(strings.devicesLegacyPairingNotice)),
            TextButton(
              key: const Key('devices-legacy-notice-dismiss'),
              onPressed: () =>
                  intents.send(const AcknowledgeLegacyPairingNotice()),
              child: Text(strings.devicesDismiss),
            ),
          ],
        ),
      ),
    );
  }
}

/// Joins this device to a LicoArc station.
class DevicesEnrollCard extends StatefulWidget {
  const DevicesEnrollCard({
    super.key,
    required this.busy,
    required this.intents,
  });

  final bool busy;
  final IntentSink<DevicesIntent> intents;

  @override
  State<DevicesEnrollCard> createState() => _DevicesEnrollCardState();
}

class _DevicesEnrollCardState extends State<DevicesEnrollCard> {
  final _station = TextEditingController();
  final _invitation = TextEditingController();
  final _ca = TextEditingController();

  @override
  void dispose() {
    _station.dispose();
    _invitation.dispose();
    _ca.dispose();
    super.dispose();
  }

  void _enroll() => widget.intents.send(
    EnrollDevice(
      station: _station.text,
      invitation: _invitation.text,
      caPem: _ca.text,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final enabled = !widget.busy;
    return Card(
      key: const Key('devices-enroll-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(
              icon: Icons.hub_outlined,
              title: strings.devicesEnrollTitle,
            ),
            const SizedBox(height: 8),
            Text(
              strings.devicesEnrollHint,
              style: TextStyle(color: colors.textMuted, height: 1.35),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('devices-enroll-station'),
              controller: _station,
              enabled: enabled,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.link_outlined),
                labelText: strings.devicesStation,
                hintText: 'https://station.example.com',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('devices-enroll-invitation'),
              controller: _invitation,
              enabled: enabled,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.confirmation_number_outlined),
                labelText: strings.devicesInvitation,
                hintText: 'btm1.…',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('devices-enroll-ca'),
              controller: _ca,
              enabled: enabled,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 2,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.verified_user_outlined),
                labelText: strings.devicesCaPem,
                hintText: '-----BEGIN CERTIFICATE-----',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('devices-enroll-submit'),
                onPressed: enabled ? _enroll : null,
                icon: const Icon(Icons.login, size: 18),
                label: Text(strings.devicesEnroll),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The station this device joined.
class DevicesStationCard extends StatelessWidget {
  const DevicesStationCard({super.key, required this.projection});

  final DevicesProjection projection;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Card(
      key: const Key('devices-station-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EndpointStatusRow(
              key: const Key('devices-station'),
              label: strings.devicesEnrolledStation,
              value: projection.station,
            ),
            EndpointStatusRow(
              key: const Key('devices-mailbox'),
              label: strings.devicesMailbox,
              value: projection.mailboxId,
            ),
          ],
        ),
      ),
    );
  }
}

/// Offers a pairing code, claims another device's code, and shows progress.
class DevicesPairingCard extends StatefulWidget {
  const DevicesPairingCard({
    super.key,
    required this.projection,
    required this.busy,
    required this.intents,
  });

  final DevicesProjection projection;
  final bool busy;
  final IntentSink<DevicesIntent> intents;

  @override
  State<DevicesPairingCard> createState() => _DevicesPairingCardState();
}

class _DevicesPairingCardState extends State<DevicesPairingCard> {
  final _label = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _code.dispose();
    super.dispose();
  }

  void _claim() {
    widget.intents.send(
      ClaimDevicePairing(code: _code.text, label: _label.text),
    );
    _code.clear();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final projection = widget.projection;
    final enabled = !widget.busy;
    return Card(
      key: const Key('devices-pairing-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(
              icon: Icons.devices_outlined,
              title: strings.devicesPairTitle,
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('devices-pair-label'),
              controller: _label,
              enabled: enabled,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.label_outline),
                labelText: strings.devicesPairLabel,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const Key('devices-pair-offer'),
                onPressed: enabled
                    ? () => widget.intents.send(
                        OfferDevicePairing(label: _label.text),
                      )
                    : null,
                icon: const Icon(Icons.qr_code_2_outlined, size: 18),
                label: Text(strings.devicesOfferPairing),
              ),
            ),
            if (projection.offerCode.isNotEmpty) ...[
              const SizedBox(height: 12),
              _OfferedCode(code: projection.offerCode, intents: widget.intents),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('devices-pair-claim-code'),
                    controller: _code,
                    enabled: enabled,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.pin_outlined),
                      labelText: strings.devicesClaimCode,
                    ),
                    onSubmitted: enabled ? (_) => _claim() : null,
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  key: const Key('devices-pair-claim'),
                  onPressed: enabled ? _claim : null,
                  child: Text(strings.devicesClaim),
                ),
              ],
            ),
            if (projection.pairings.isNotEmpty) ...[
              const Divider(height: 32),
              Text(
                strings.devicesPairings,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              for (final pairing in projection.pairings)
                _PairingRow(
                  key: Key('devices-pairing-${pairing.pairingId}'),
                  pairing: pairing,
                  enabled: enabled,
                  intents: widget.intents,
                  colors: colors,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OfferedCode extends StatelessWidget {
  const _OfferedCode({required this.code, required this.intents});

  final String code;
  final IntentSink<DevicesIntent> intents;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return Container(
      key: const Key('devices-pair-offered-code'),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: continuousHairlineDecoration(
        color: colors.isDark
            ? LicoPaneGlass.contentInnerCardFill
            : colors.surfaceLow,
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        stroke: colors.line.withAlpha(80),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.devicesPairingCode,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  code,
                  key: const Key('devices-pair-code-text'),
                  maxLines: 3,
                  style: TextStyle(
                    color: colors.accent,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  strings.devicesOfferedCodeHint,
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('devices-pair-copy-code'),
            tooltip: strings.devicesCopyPairingCode,
            icon: const Icon(Icons.copy_outlined),
            color: colors.accent,
            onPressed: () => intents.send(const CopyDevicePairingCode()),
          ),
          IconButton(
            key: const Key('devices-pair-dismiss-code'),
            tooltip: strings.devicesDismiss,
            icon: const Icon(Icons.close),
            onPressed: () => intents.send(const DismissDevicePairingCode()),
          ),
        ],
      ),
    );
  }
}

class _PairingRow extends StatelessWidget {
  const _PairingRow({
    super.key,
    required this.pairing,
    required this.enabled,
    required this.intents,
    required this.colors,
  });

  final DevicePairingView pairing;
  final bool enabled;
  final IntentSink<DevicesIntent> intents;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final (stateLabel, stateColor, stateIcon) = switch (pairing.state) {
      DevicePairingStateView.awaitingClaim => (
        strings.devicesStateAwaitingClaim,
        colors.textMuted,
        Icons.hourglass_empty,
      ),
      DevicePairingStateView.awaitingReply => (
        strings.devicesStateAwaitingReply,
        colors.textMuted,
        Icons.hourglass_top,
      ),
      DevicePairingStateView.completed => (
        strings.devicesStateCompleted,
        colors.success,
        Icons.check_circle_outline,
      ),
      DevicePairingStateView.failed => (
        strings.devicesStateFailed,
        colors.error,
        Icons.error_outline,
      ),
    };
    final role = pairing.role == DevicePairingRoleView.offerer
        ? strings.devicesRoleOfferer
        : strings.devicesRoleClaimer;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(stateIcon, color: stateColor, size: 20),
      title: Text(stateLabel, style: TextStyle(color: stateColor)),
      subtitle: Text(
        [role, if (pairing.createdAt.isNotEmpty) pairing.createdAt].join(' · '),
      ),
      trailing: pairing.pending
          ? TextButton(
              key: Key('devices-pairing-cancel-${pairing.pairingId}'),
              onPressed: enabled
                  ? () => intents.send(CancelDevicePairing(pairing.pairingId))
                  : null,
              child: Text(strings.devicesCancelPairing),
            )
          : null,
    );
  }
}

/// Paired devices; choosing one addresses the message card to it.
class DevicesPeersCard extends StatelessWidget {
  const DevicesPeersCard({
    super.key,
    required this.projection,
    required this.selectedPeerId,
    required this.busy,
    required this.intents,
    required this.onSelect,
  });

  final DevicesProjection projection;
  final String selectedPeerId;
  final bool busy;
  final IntentSink<DevicesIntent> intents;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return Card(
      key: const Key('devices-peers-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(
              icon: Icons.computer_outlined,
              title: strings.devicesPeers,
            ),
            const SizedBox(height: 8),
            if (projection.peers.isEmpty)
              Text(
                strings.devicesNoPeers,
                key: const Key('devices-peers-empty'),
                style: TextStyle(color: colors.textMuted),
              )
            else
              for (final peer in projection.peers)
                ListTile(
                  key: Key('devices-peer-${peer.peerId}'),
                  contentPadding: EdgeInsets.zero,
                  selected: peer.peerId == selectedPeerId,
                  selectedColor: colors.accent,
                  leading: Icon(
                    peer.peerId == selectedPeerId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  title: Text(peerTitle(peer)),
                  subtitle: Text(
                    [
                      peer.peerId,
                      if (peer.pairedAt.isNotEmpty)
                        '${strings.devicesPairedAt} ${peer.pairedAt}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => onSelect(peer.peerId),
                  trailing: TextButton(
                    key: Key('devices-peer-unpair-${peer.peerId}'),
                    style: TextButton.styleFrom(foregroundColor: colors.error),
                    onPressed: busy
                        ? null
                        : () => _confirmUnpair(context, peer),
                    child: Text(strings.devicesUnpair),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmUnpair(BuildContext context, DevicePeerView peer) async {
    final strings = LicoStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('devices-unpair-confirm'),
        title: Text(strings.devicesUnpair),
        content: Text(strings.devicesUnpairConfirm(peerTitle(peer))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('devices-unpair-confirm-submit'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.devicesUnpair),
          ),
        ],
      ),
    );
    if (confirmed == true) intents.send(UnpairDevice(peer.peerId));
  }
}

String peerTitle(DevicePeerView peer) =>
    peer.label.isEmpty ? peer.peerId : peer.label;

/// Sends an agent message to the chosen peer and lists its results.
class DevicesMessageCard extends StatefulWidget {
  const DevicesMessageCard({
    super.key,
    required this.peer,
    required this.projection,
    required this.busy,
    required this.intents,
  });

  final DevicePeerView peer;
  final DevicesProjection projection;
  final bool busy;
  final IntentSink<DevicesIntent> intents;

  @override
  State<DevicesMessageCard> createState() => _DevicesMessageCardState();
}

class _DevicesMessageCardState extends State<DevicesMessageCard> {
  final _agent = TextEditingController();
  final _body = TextEditingController();

  @override
  void dispose() {
    _agent.dispose();
    _body.dispose();
    super.dispose();
  }

  void _send() {
    widget.intents.send(
      SendDeviceMessage(
        peerId: widget.peer.peerId,
        agent: _agent.text,
        body: _body.text,
      ),
    );
    _body.clear();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final enabled = !widget.busy;
    final results = [
      for (final result in widget.projection.results)
        if (result.peerId == widget.peer.peerId) result,
    ];
    return Card(
      key: const Key('devices-message-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(
              icon: Icons.send_outlined,
              title:
                  '${strings.devicesMessageTitle} · ${peerTitle(widget.peer)}',
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('devices-message-agent'),
              controller: _agent,
              enabled: enabled,
              autocorrect: false,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.smart_toy_outlined),
                labelText: strings.devicesMessageAgent,
                hintText: 'codex',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('devices-message-body'),
              controller: _body,
              enabled: enabled,
              minLines: 2,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: strings.devicesMessageBody,
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (widget.projection.outstandingMessageCount > 0)
                  Expanded(
                    child: Text(
                      strings.devicesOutstanding(
                        widget.projection.outstandingMessageCount,
                      ),
                      key: const Key('devices-message-outstanding'),
                      style: TextStyle(color: colors.textMuted),
                    ),
                  )
                else
                  const Spacer(),
                FilledButton.icon(
                  key: const Key('devices-message-send'),
                  onPressed: enabled ? _send : null,
                  icon: const Icon(Icons.send, size: 18),
                  label: Text(strings.devicesSendMessage),
                ),
              ],
            ),
            const Divider(height: 32),
            Text(
              strings.devicesResults,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (results.isEmpty)
              Text(
                strings.devicesNoResults,
                key: const Key('devices-results-empty'),
                style: TextStyle(color: colors.textMuted),
              )
            else
              for (final result in results)
                _ResultTile(
                  key: Key('devices-result-${result.commandId}'),
                  result: result,
                ),
          ],
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({super.key, required this.result});

  final DeviceMessageResultView result;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final color = result.completed ? colors.success : colors.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: continuousHairlineDecoration(
          color: colors.isDark
              ? LicoPaneGlass.contentInnerCardFill
              : colors.surfaceLow,
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          stroke: colors.line.withAlpha(80),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  result.completed
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  color: color,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  result.completed
                      ? strings.devicesResultCompleted
                      : strings.devicesResultFailed,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  result.completedAt,
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(result.outputText),
          ],
        ),
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon),
        const SizedBox(width: 10),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
      ],
    );
  }
}
