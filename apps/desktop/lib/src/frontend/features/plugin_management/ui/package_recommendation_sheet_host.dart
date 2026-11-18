import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_inputs.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_providers.dart';

/// Shows the one confirmation for a recommended package set.
///
/// It wraps the shell instead of a destination, because the first-launch offer
/// is settled before any destination is entered: the recommended set must be
/// answerable from wherever the client happens to be, and it must never depend
/// on the user finding the package center.
///
/// Opening the dialog is deferred to a post-frame callback, so the shell paints
/// its first frame before the confirmation appears and the offer can never block
/// the frame that would show it. Dismissing the dialog at the barrier answers it
/// with a decline, which is recorded durably.
final class PackageRecommendationSheetHost extends StatelessWidget {
  const PackageRecommendationSheetHost({
    super.key,
    required this.binding,
    required this.child,
  });

  final PluginManagementBinding binding;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      AsyncRegion<PluginCatalogInputs, IntentSink<PluginManagementIntent>>(
        source: pluginCatalogInputsProvider,
        actions: binding.intents,
        loading: (_, _) => child,
        data: (context, inputs, _) => _RecommendationWatcher(
          binding: binding,
          recommendation: inputs.recommendation,
          child: child,
        ),
      );
}

final class _RecommendationWatcher extends StatefulWidget {
  const _RecommendationWatcher({
    required this.binding,
    required this.recommendation,
    required this.child,
  });

  final PluginManagementBinding binding;
  final PackageRecommendationProjection? recommendation;
  final Widget child;

  @override
  State<_RecommendationWatcher> createState() => _RecommendationWatcherState();
}

final class _RecommendationWatcherState extends State<_RecommendationWatcher> {
  /// The identity of the offer already presented, so a rebuild of the shell
  /// never opens a second dialog for the same recommendation.
  String? _presented;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(_RecommendationWatcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _schedule() {
    final recommendation = widget.recommendation;
    if (recommendation == null || recommendation.isEmpty) {
      _presented = null;
      return;
    }
    final identity = _identity(recommendation);
    if (_presented == identity) return;
    _presented = identity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_present(recommendation));
    });
  }

  Future<void> _present(PackageRecommendationProjection recommendation) async {
    final strings = LicoStrings.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        key: const Key('package-recommendation-confirmation'),
        title: Text(
          recommendation.firstLaunch
              ? (strings.isChinese
                    ? '安装推荐的软件包？'
                    : 'Install recommended packages?')
              : (strings.isChinese ? '安装此能力？' : 'Install this capability?'),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                strings.isChinese
                    ? 'LicoUp 会为检测到的 Agent 安装以下 LicoUp 软件包。'
                          '第三方 Agent 本身的安装由 Agent Hub 负责。'
                    : 'LicoUp will install the following LicoUp packages for '
                          'the detected Agents. Installing the third-party '
                          'Agent itself stays with Agent Hub.',
              ),
              const SizedBox(height: 12),
              for (final item in recommendation.recommendations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${item.label}',
                    key: Key('package-recommendation-item-${item.packageId}'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('package-recommendation-decline'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.isChinese ? '不安装' : 'Not now'),
          ),
          FilledButton(
            key: const Key('package-recommendation-accept'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(strings.isChinese ? '确认安装' : 'Install'),
          ),
        ],
      ),
    );
    // A dismissed dialog is a decline: it is recorded durably, so the same
    // packages are never offered again on this data home.
    widget.binding.intents.send(
      ResolvePackageRecommendation(accepted: accepted == true),
    );
  }

  static String _identity(PackageRecommendationProjection recommendation) => [
    recommendation.firstLaunch ? 'first-launch' : 'first-use',
    for (final item in recommendation.recommendations) item.packageId,
  ].join('|');

  @override
  Widget build(BuildContext context) => widget.child;
}
