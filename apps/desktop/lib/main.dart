import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:licoup/app.dart';
import 'package:licoup/src/composition/product_acceptance/agent_conversation_release_live.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/platform/storage/single_instance_guard.dart';

const _agentConversationReleaseLive = bool.fromEnvironment(
  'LICO_AGENT_CONVERSATION_RELEASE_LIVE',
);

SingleInstanceGuard? _instanceGuard;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_agentConversationReleaseLive) {
    runAgentConversationReleaseLive();
    return;
  }
  // One client instance per machine: a duplicate launch exits before any
  // bootstrap work (target scans, bridge workloads) can start.
  _instanceGuard = await SingleInstanceGuard.tryAcquire(
    await SingleInstanceGuard.lockFileFor(PortableDataRoot()),
  );
  if (_instanceGuard == null) {
    exit(0);
  }
  runApp(const LicoApp());
}
