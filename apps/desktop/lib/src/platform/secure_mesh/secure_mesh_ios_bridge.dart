import 'package:flutter/services.dart';

import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

const String secureMeshIosChannelName = 'licomesh.secure_mesh.ios';

class SecureMeshIosBridge extends SecureMeshMobileBridge {
  const SecureMeshIosBridge({
    super.channel = const MethodChannel(secureMeshIosChannelName),
  }) : super(
         platform: 'ios',
         unavailableCode: 'secure_mesh_ios_bridge_unavailable',
         unavailableMessage: 'Secure Mesh iOS bridge is unavailable.',
       );
}
