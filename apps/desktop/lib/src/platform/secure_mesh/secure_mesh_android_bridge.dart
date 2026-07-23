import 'package:flutter/services.dart';

import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

const String secureMeshAndroidChannelName = 'licomesh.secure_mesh.android';

class SecureMeshAndroidBridge extends SecureMeshMobileBridge {
  const SecureMeshAndroidBridge({
    super.channel = const MethodChannel(secureMeshAndroidChannelName),
  }) : super(
         platform: 'android',
         unavailableCode: 'secure_mesh_android_bridge_unavailable',
         unavailableMessage: 'Secure Mesh Android bridge is unavailable.',
       );
}
