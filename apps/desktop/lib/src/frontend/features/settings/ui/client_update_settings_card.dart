import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

class ClientUpdateSettingsCard extends StatefulWidget {
  const ClientUpdateSettingsCard({super.key, required this.binding});

  final SettingsBinding binding;

  @override
  State<ClientUpdateSettingsCard> createState() =>
      _ClientUpdateSettingsCardState();
}

class _ClientUpdateSettingsCardState extends State<ClientUpdateSettingsCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.binding.intents.send(const HydrateClientUpdateIdentity());
      }
    });
  }

  void _checkFromGithub() {
    widget.binding.intents.send(const CheckForClientUpdate());
  }

  void _downloadFromGithub() {
    widget.binding.intents.send(const DownloadClientUpdate());
  }

  void _applyAndRestart() {
    widget.binding.intents.send(const ApplyClientUpdate());
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<
      SettingsProjection,
      SettingsClientUpdateProjection
    >(
      source: widget.binding.projection,
      select: (projection) => projection.clientUpdate,
      builder: _buildCard,
    );
  }

  Widget _buildCard(
    BuildContext context,
    SettingsClientUpdateProjection status,
  ) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final busy =
        status.phase == ClientUpdatePhase.checking ||
        status.phase == ClientUpdatePhase.downloading ||
        status.phase == ClientUpdatePhase.verifying;
    final canCheck = !busy;
    final canDownload =
        !busy &&
        status.updateAvailable &&
        status.phase == ClientUpdatePhase.updateAvailable;
    final canApply =
        !busy &&
        (status.phase == ClientUpdatePhase.verified ||
            status.phase == ClientUpdatePhase.applyPlanned);
    final sourceAddress = clientUpdatePublicSourceAddress(
      repo: widget.binding.projection.current.clientUpdateRepo,
      githubReleaseUrl: status.githubReleaseUrl,
    );

    final presentation = layoutSettingsPresentationOf(context);
    return Padding(
      key: const Key('client-update-settings-card'),
      padding: presentation.rowPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.system_update_alt,
                color: colors.textSecondary,
                size: 18,
              ),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.clientUpdate,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: LicoContentSpacing.inline / 2),
                    Text(
                      strings.clientUpdateHint,
                      style: TextStyle(fontSize: 11, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: LicoContentSpacing.item),
          _InfoLine(
            label: strings.version,
            value: status.runningVersion.isEmpty
                ? strings.notSelected
                : status.runningVersion,
          ),
          if (status.runningReleaseTrack == ReleaseTrack.nightly)
            _ReleaseTrackSelector(
              selected: status.targetReleaseTrack,
              enabled: !busy,
              nightlyLabel: strings.nightlyChannel,
              stableLabel: strings.stableChannel,
              onSelected: (track) => widget.binding.intents.send(
                SetClientUpdateReleaseTrack(track),
              ),
            )
          else
            _InfoLine(label: strings.channel, value: strings.stableChannel),
          _InfoLine(
            label: strings.updateSource,
            value: strings.updateSourceGithub,
          ),
          _InfoLine(
            key: const Key('client-update-source-address'),
            label: strings.sourceAddress,
            value: sourceAddress,
          ),
          if (status.availableVersion.isNotEmpty)
            _InfoLine(
              label: strings.availableVersion,
              value: status.availableVersion,
            ),
          if (status.artifactSha256.isNotEmpty)
            _InfoLine(label: strings.digest, value: status.artifactSha256),
          const SizedBox(height: LicoContentSpacing.item),
          Wrap(
            spacing: LicoContentSpacing.compact,
            runSpacing: LicoContentSpacing.compact,
            children: [
              FilledButton(
                key: const Key('client-update-check-github'),
                onPressed: canCheck ? _checkFromGithub : null,
                child: Text(strings.checkUpdate),
              ),
              OutlinedButton(
                key: const Key('client-update-download-local'),
                onPressed: canDownload ? _downloadFromGithub : null,
                child: Text(strings.downloadToLocal),
              ),
              FilledButton(
                key: const Key('client-update-apply-restart'),
                onPressed: canApply ? _applyAndRestart : null,
                child: Text(strings.updateAndRestart),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReleaseTrackSelector extends StatelessWidget {
  const _ReleaseTrackSelector({
    required this.selected,
    required this.enabled,
    required this.nightlyLabel,
    required this.stableLabel,
    required this.onSelected,
  });

  final ReleaseTrack selected;
  final bool enabled;
  final String nightlyLabel;
  final String stableLabel;
  final ValueChanged<ReleaseTrack> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: LicoContentSpacing.inline),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              LicoStrings.of(context).channel,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<ReleaseTrack>(
                key: const Key('client-update-release-track'),
                segments: [
                  ButtonSegment(
                    value: ReleaseTrack.nightly,
                    label: Text(nightlyLabel),
                  ),
                  ButtonSegment(
                    value: ReleaseTrack.stable,
                    label: Text(stableLabel),
                  ),
                ],
                selected: {selected},
                showSelectedIcon: false,
                onSelectionChanged: enabled
                    ? (selection) => onSelected(selection.single)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: LicoContentSpacing.inline),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.text),
            ),
          ),
        ],
      ),
    );
  }
}
