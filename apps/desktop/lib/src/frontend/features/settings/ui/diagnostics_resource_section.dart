import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/settings/ui/client_resource_usage_card.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';

/// Renders the composition-owned live client and agent memory samplers.
class DiagnosticsResourceSection extends StatelessWidget {
  const DiagnosticsResourceSection({super.key, required this.binding});

  final SettingsBinding binding;

  @override
  Widget build(BuildContext context) {
    return ClientResourceUsageCard(binding: binding);
  }
}
