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
      ({SettingsClientUpdateProjection status, String repository})
    >(
      source: widget.binding.projection,
      select: (projection) => (
        status: projection.clientUpdate,
        repository: projection.clientUpdateRepo,
      ),
      builder: (context, selected) =>
          _buildCard(context, selected.status, selected.repository),
    );
  }

  Widget _buildCard(
    BuildContext context,
    SettingsClientUpdateProjection status,
    String repository,
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
      repo: repository,
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
                child: Text(
                  strings.clientUpdate,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.text,
                    fontWeight: FontWeight.w600,
                  ),
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
            key: const Key('client-update-source-address'),
            label: strings.sourceAddress,
            value: sourceAddress,
          ),
          if (status.availableVersion.isNotEmpty)
            _InfoLine(
              label: strings.availableVersion,
              value: status.availableVersion,
            ),
          if (status.phase != ClientUpdatePhase.idle)
            Padding(
              padding: const EdgeInsets.only(top: LicoContentSpacing.compact),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _updatePhaseLabel(status.phase, strings.isChinese),
                  key: const Key('client-update-status'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: status.phase == ClientUpdatePhase.failed
                        ? colors.error
                        : colors.textSecondary,
                  ),
                ),
              ),
            ),
          const SizedBox(height: LicoContentSpacing.item),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 560 ? 3 : 1;
              final width =
                  (constraints.maxWidth -
                      LicoContentSpacing.compact * (columns - 1)) /
                  columns;
              final style = ButtonStyle(
                minimumSize: const WidgetStatePropertyAll(Size.zero),
                fixedSize: WidgetStatePropertyAll(Size(width, 40)),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 12),
                ),
                textStyle: WidgetStatePropertyAll(
                  Theme.of(context).textTheme.labelLarge,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
              return Wrap(
                spacing: LicoContentSpacing.compact,
                runSpacing: LicoContentSpacing.compact,
                children: [
                  OutlinedButton(
                    key: const Key('client-update-check-github'),
                    style: style,
                    onPressed: canCheck ? _checkFromGithub : null,
                    child: Text(strings.checkUpdate),
                  ),
                  OutlinedButton(
                    key: const Key('client-update-download-local'),
                    style: style,
                    onPressed: canDownload ? _downloadFromGithub : null,
                    child: Text(strings.downloadToLocal),
                  ),
                  FilledButton(
                    key: const Key('client-update-apply-restart'),
                    style: style,
                    onPressed: canApply ? _applyAndRestart : null,
                    child: Text(strings.updateAndRestart),
                  ),
                ],
              );
            },
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
      padding: const EdgeInsets.symmetric(vertical: LicoContentSpacing.compact),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              LicoStrings.of(context).channel,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.textMuted),
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
                style: ButtonStyle(
                  textStyle: WidgetStatePropertyAll(
                    Theme.of(context).textTheme.bodyMedium,
                  ),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
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
      padding: const EdgeInsets.symmetric(vertical: LicoContentSpacing.compact),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.text),
            ),
          ),
        ],
      ),
    );
  }
}

String _updatePhaseLabel(
  ClientUpdatePhase phase,
  bool chinese,
) => switch (phase) {
  ClientUpdatePhase.idle => '',
  ClientUpdatePhase.checking => chinese ? '正在检查更新…' : 'Checking for updates…',
  ClientUpdatePhase.upToDate => chinese ? '已是最新版本' : 'Up to date',
  ClientUpdatePhase.updateAvailable => chinese ? '有可用更新' : 'Update available',
  ClientUpdatePhase.downloading => chinese ? '正在下载…' : 'Downloading…',
  ClientUpdatePhase.downloaded => chinese ? '下载完成' : 'Downloaded',
  ClientUpdatePhase.verifying => chinese ? '正在验证…' : 'Verifying…',
  ClientUpdatePhase.verified || ClientUpdatePhase.applyPlanned =>
    chinese ? '已验证，可以更新并重启' : 'Verified and ready to restart',
  ClientUpdatePhase.applied => chinese ? '更新已安装' : 'Update installed',
  ClientUpdatePhase.failed =>
    chinese ? '更新失败，请重试' : 'Update failed. Try again.',
};
