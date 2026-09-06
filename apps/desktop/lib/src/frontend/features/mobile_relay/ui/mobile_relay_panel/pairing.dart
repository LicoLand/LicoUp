import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/qr.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/endpoint_configuration.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';

class MobileRelayPairingWorkspaceCard extends StatelessWidget {
  const MobileRelayPairingWorkspaceCard({
    super.key,
    required this.projection,
    required this.intents,
    required this.stationBaseUrlController,
  });

  final MobileRelayProjection projection;
  final IntentSink<MobileRelayIntent> intents;
  final TextEditingController stationBaseUrlController;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final inviteText = projection.pairingInvite.trim();
    final pairingCode = projection.pairingCode.trim();

    return Container(
      key: const Key('pairing-qr-workspace-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(LicoRadius.card),
        border: Border.all(color: colors.line.withAlpha(90)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final info = _MobileRelayPairingInfoPane(
            projection: projection,
            intents: intents,
            stationBaseUrlController: stationBaseUrlController,
            pairingCode: pairingCode,
          );
          final qr = MobileRelayPairingQrFrame(
            inviteText: inviteText,
            busy: projection.busy,
            stationConfigured: projection.stationConfigured,
            onGenerate: () async => intents.send(const CreateRelayPairing()),
          );
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                info,
                const SizedBox(height: 18),
                Align(alignment: Alignment.center, child: qr),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: info),
              const SizedBox(width: 24),
              qr,
            ],
          );
        },
      ),
    );
  }
}

class _MobileRelayPairingInfoPane extends StatelessWidget {
  const _MobileRelayPairingInfoPane({
    required this.projection,
    required this.intents,
    required this.stationBaseUrlController,
    required this.pairingCode,
  });

  final MobileRelayProjection projection;
  final IntentSink<MobileRelayIntent> intents;
  final TextEditingController stationBaseUrlController;
  final String pairingCode;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final busy = projection.busy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.station,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: colors.textMuted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        EndpointUrlField(
          key: const Key('mobile-relay-station-base-url-field'),
          controller: stationBaseUrlController,
          enabled: !busy,
          hintText: 'https://station.example.com',
          saveTooltip: strings.saveStation,
          onSave: busy
              ? null
              : () => intents.send(
                  ConfigureRelayStation(stationBaseUrlController.text),
                ),
        ),
        const SizedBox(height: 16),
        MobileRelayPairingInfoRow(
          label: strings.status,
          value: projection.paired ? strings.paired : strings.waiting,
        ),
        MobileRelayPairingInfoRow(
          label: strings.pairingId,
          value: projection.pairingId,
        ),
        MobileRelayPairingInfoRow(
          label: strings.expires,
          value: projection.pairingExpiresLabel,
        ),
        if (pairingCode.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            strings.oneTimePairingCodeNotice,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: BoxDecoration(
              color: colors.surfaceLow,
              borderRadius: BorderRadius.circular(LicoRadius.chip),
              border: Border.all(color: colors.line.withAlpha(80)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.pairingCode,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        pairingCode,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: colors.accent,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: strings.copyPairingCode,
                  icon: const Icon(Icons.copy_outlined),
                  color: colors.accent,
                  onPressed: () =>
                      intents.send(CopyRelayPairingCode(pairingCode)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class MobileRelayPairingInfoRow extends EndpointStatusRow {
  const MobileRelayPairingInfoRow({
    super.key,
    required super.label,
    required super.value,
  });
}
