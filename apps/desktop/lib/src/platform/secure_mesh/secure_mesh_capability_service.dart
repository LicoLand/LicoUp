import 'package:flutter_client/src/contracts/secure_mesh_capability_models.dart';

class SecureMeshCapabilityService {
  const SecureMeshCapabilityService();

  SecureMeshCapabilityProjection? projectStatus(
    Map<String, dynamic> nativeStatus,
  ) {
    if (!nativeStatus.containsKey('capabilityProjection')) {
      return null;
    }
    final rawProjection = nativeStatus['capabilityProjection'];
    if (rawProjection is! Map) {
      throw const FormatException(
        'Secure Mesh native capability projection must be an object.',
      );
    }
    if (rawProjection.keys.any((key) => key is! String)) {
      throw const FormatException(
        'Secure Mesh native capability projection contains a non-text field.',
      );
    }
    return SecureMeshCapabilityProjection.fromJson(
      Map<String, dynamic>.from(rawProjection),
    );
  }
}
