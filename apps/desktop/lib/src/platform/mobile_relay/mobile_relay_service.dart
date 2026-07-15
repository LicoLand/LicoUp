import 'dart:convert';
import 'dart:io' show Platform, Process;

import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/contracts/secure_mesh_mls_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_kt_models.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_ios_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

export 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
export 'package:flutter_client/src/contracts/secure_mesh_mls_models.dart';
export 'package:flutter_client/src/contracts/secure_mesh_kt_models.dart';

part 'mobile_relay_secure_mesh_service.dart';
part 'mobile_relay_service_ops.dart';

bool _supportsLocalMobileProviderOAuth(String providerId) {
  final provider = mobileAgentProviderOrNull(providerId);
  return provider?.supportsLocalOAuthLogin == true;
}

Map<String, dynamic> _localMobileProviderOAuthUnavailable(String providerId) {
  final provider = mobileAgentProviderOrNull(providerId);
  final deferred = provider?.localOAuthDeferred == true;
  return {
    'ok': false,
    'status': deferred
        ? 'android_provider_deferred'
        : 'unsupported_local_oauth_provider',
    'code': deferred
        ? 'android_provider_deferred'
        : 'unsupported_local_oauth_provider',
    'providerId': providerId,
    if (deferred) 'supportState': 'deferred_optional_service',
    'bodyRedacted': true,
  };
}

class MobileRelayService with _MobileRelayServiceOps {
  const MobileRelayService();
}
