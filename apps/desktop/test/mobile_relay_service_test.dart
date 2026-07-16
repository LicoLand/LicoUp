import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mobile_relay/android_bridge_scenarios.dart';
import 'fixtures/mobile_relay/configuration_scenarios.dart';
import 'fixtures/mobile_relay/ios_bridge_scenarios.dart';
import 'fixtures/mobile_relay/pairing_scenarios.dart';
import 'fixtures/mobile_relay/relay_poll_scenarios.dart';
import 'fixtures/mobile_relay/session_list_scenarios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerMobileRelayConfigurationScenarios();
  registerMobileRelayPairingScenarios();
  registerMobileRelayAndroidBridgeScenarios();
  registerMobileRelayPollScenarios();
  registerMobileRelaySessionListScenarios();
  registerMobileRelayIosBridgeScenarios();
}
