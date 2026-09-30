import 'package:flutter/material.dart';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel_widgets.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';

/// Status-first update card: the headline answers "do I need to do anything?"
/// at a glance, one state-adaptive action follows it, and configuration that
/// rarely changes (channel, source address, offline download) lives behind
/// the Advanced disclosure.
class ClientUpdateSettingsCard extends StatefulWidget {
  const ClientUpdateSettingsCard({super.key, required this.binding});

  final SettingsBinding binding;

  @override
  State<ClientUpdateSettingsCard> createState() =>
      _ClientUpdateSettingsCardState();
}

class _ClientUpdateSettingsCardState extends State<ClientUpdateSettingsCard> {
  bool _advancedExpanded = false;

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
    return AsyncRegion<SettingsUpdateInputs, IntentSink<SettingsIntent>>(
      source: settingsUpdateInputsProvider,
      actions: widget.binding.intents,
      loading: (_, _) => const SizedBox.shrink(),
      data: (context, inputs, _) =>
          _buildCard(context, inputs.status, inputs.repository),
    );
  }

  Widget _buildCard(
    BuildContext context,
    SettingsClientUpdateProjection status,
    String repository,
  ) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final phase = status.phase;
    final busy =
        phase == ClientUpdatePhase.checking ||
        phase == ClientUpdatePhase.downloading ||
        phase == ClientUpdatePhase.verifying;
    final canCheck = !busy;
    final canDownload =
        !busy &&
        status.updateAvailable &&
        phase == ClientUpdatePhase.updateAvailable;
    final canApply =
        !busy &&
        (phase == ClientUpdatePhase.verified ||
            phase == ClientUpdatePhase.applyPlanned);
    final sourceAddress = clientUpdatePublicSourceAddress(
      repo: repository,
      githubReleaseUrl: status.githubReleaseUrl,
    );
    final statusLabel = _updateStatusLabel(
      phase,
      strings.isChinese,
      availableVersion: status.availableVersion,
    );
    final statusColor = _updateStatusColor(phase, colors);
    final failureDetail = phase == ClientUpdatePhase.failed
        ? _updateFailureDetail(status.errorCode, strings.isChinese)
        : '';

    final presentation = layoutSettingsPresentationOf(context);
    return Column(
      key: const Key('client-update-settings-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LicoSectionHeader(
          key: const Key('settings-section-header-updates'),
          title: strings.clientUpdate,
          leading: Icon(
            Icons.system_update_alt,
            color: colors.textSecondary,
            size: 18,
          ),
          padding: presentation.sectionHeaderPadding,
        ),
        Padding(
          padding: presentation.rowPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: _UpdateHeadline(
                      version: status.runningVersion.isEmpty
                          ? strings.notSelected
                          : status.runningVersion,
                      channel:
                          status.runningReleaseTrack == ReleaseTrack.nightly
                          ? strings.nightlyChannel
                          : strings.stableChannel,
                      statusLabel: statusLabel,
                      statusColor: statusColor,
                    ),
                  ),
                  const SizedBox(width: LicoContentSpacing.item),
                  _updateFlowPhase(phase)
                      ? FilledButton(
                          key: const Key('client-update-apply-restart'),
                          style: _updateActionStyle(context),
                          onPressed: canDownload
                              ? _downloadFromGithub
                              : (canApply ? _applyAndRestart : null),
                          child: Text(strings.updateAndRestart),
                        )
                      : OutlinedButton(
                          key: const Key('client-update-check-github'),
                          style: _updateActionStyle(context),
                          onPressed: canCheck ? _checkFromGithub : null,
                          child: Text(strings.checkUpdate),
                        ),
                ],
              ),
              if (failureDetail.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(
                    top: LicoContentSpacing.inline,
                  ),
                  child: Text(
                    failureDetail,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              _AdvancedDisclosure(
                expanded: _advancedExpanded,
                onToggle: () =>
                    setState(() => _advancedExpanded = !_advancedExpanded),
                label: strings.clientUpdateAdvanced,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                      _InfoLine(
                        label: strings.channel,
                        value: strings.stableChannel,
                      ),
                    _InfoLine(
                      key: const Key('client-update-source-address'),
                      label: strings.sourceAddress,
                      value: sourceAddress,
                    ),
                    const SizedBox(height: LicoContentSpacing.compact),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        key: const Key('client-update-download-local'),
                        style: _updateActionStyle(context),
                        onPressed: canDownload ? _downloadFromGithub : null,
                        child: Text(strings.downloadToLocal),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

bool _updateFlowPhase(ClientUpdatePhase phase) => switch (phase) {
  ClientUpdatePhase.updateAvailable ||
  ClientUpdatePhase.downloading ||
  ClientUpdatePhase.downloaded ||
  ClientUpdatePhase.verifying ||
  ClientUpdatePhase.verified ||
  ClientUpdatePhase.applyPlanned => true,
  _ => false,
};

ButtonStyle _updateActionStyle(BuildContext context) => ButtonStyle(
  fixedSize: const WidgetStatePropertyAll(
    Size.fromHeight(settingsControlHeight),
  ),
  padding: const WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: LicoContentSpacing.item),
  ),
  textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelLarge),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _UpdateHeadline extends StatelessWidget {
  const _UpdateHeadline({
    required this.version,
    required this.channel,
    required this.statusLabel,
    required this.statusColor,
  });

  final String version;
  final String channel;
  final String statusLabel;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            '$version · $channel',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (statusLabel.isNotEmpty) ...[
          const SizedBox(width: LicoContentSpacing.item),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: LicoContentSpacing.inline),
          Flexible(
            flex: 0,
            child: Semantics(
              liveRegion: true,
              child: Text(
                statusLabel,
                key: const Key('client-update-status'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AdvancedDisclosure extends StatelessWidget {
  const _AdvancedDisclosure({
    required this.expanded,
    required this.onToggle,
    required this.label,
    required this.child,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const Key('client-update-advanced-toggle'),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: LicoContentSpacing.compact,
            ),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: LicoContentSpacing.inline),
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded) child,
      ],
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
              child: SettingsSegmentedControl<ReleaseTrack>(
                key: const Key('client-update-release-track'),
                segments: [
                  (value: ReleaseTrack.nightly, label: nightlyLabel),
                  (value: ReleaseTrack.stable, label: stableLabel),
                ],
                selected: selected,
                enabled: enabled,
                width: settingsControlWidth,
                onChanged: onSelected,
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

String _updateStatusLabel(
  ClientUpdatePhase phase,
  bool chinese, {
  String availableVersion = '',
}) => switch (phase) {
  ClientUpdatePhase.idle => '',
  ClientUpdatePhase.checking => chinese ? '正在检查…' : 'Checking…',
  ClientUpdatePhase.upToDate => chinese ? '已是最新版本' : 'Up to date',
  ClientUpdatePhase.unavailable => chinese ? '暂无更新资料' : 'No update info',
  ClientUpdatePhase.updateAvailable =>
    availableVersion.isNotEmpty
        ? (chinese
              ? '新版本 $availableVersion 可用'
              : 'Version $availableVersion available')
        : (chinese ? '有可用更新' : 'Update available'),
  ClientUpdatePhase.downloading => chinese ? '正在下载…' : 'Downloading…',
  ClientUpdatePhase.downloaded => chinese ? '下载完成' : 'Downloaded',
  ClientUpdatePhase.verifying => chinese ? '正在验证…' : 'Verifying…',
  ClientUpdatePhase.verified ||
  ClientUpdatePhase.applyPlanned => chinese ? '可以更新并重启' : 'Ready to restart',
  ClientUpdatePhase.applied => chinese ? '更新已安装' : 'Update installed',
  ClientUpdatePhase.failed => chinese ? '更新失败' : 'Update failed',
};

Color _updateStatusColor(ClientUpdatePhase phase, LicoThemeColors colors) =>
    switch (phase) {
      ClientUpdatePhase.upToDate || ClientUpdatePhase.applied => colors.success,
      ClientUpdatePhase.updateAvailable ||
      ClientUpdatePhase.verified ||
      ClientUpdatePhase.applyPlanned => colors.accent,
      ClientUpdatePhase.failed => colors.error,
      _ => colors.textSecondary,
    };

String _updateFailureDetail(String errorCode, bool chinese) =>
    switch (errorCode) {
      'client_update_check_failed' =>
        chinese ? '无法检查更新，请重试' : 'Could not check for updates. Try again.',
      'client_update_download_failed' =>
        chinese ? '下载失败，请重试' : 'Download failed. Try again.',
      'client_update_verify_failed' =>
        chinese ? '更新包验证失败，请重新下载' : 'Verification failed. Download again.',
      'client_update_apply_failed' =>
        chinese ? '安装失败，请重试' : 'Installation failed. Try again.',
      _ => chinese ? '更新未完成，请重试' : 'Update incomplete. Try again.',
    };
