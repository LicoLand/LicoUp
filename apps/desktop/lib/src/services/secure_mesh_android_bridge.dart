import 'package:flutter/services.dart';

const String secureMeshAndroidChannelName = 'licolite.secure_mesh.android';

class SecureMeshAndroidBridge {
  const SecureMeshAndroidBridge({
    MethodChannel channel = const MethodChannel(secureMeshAndroidChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<Map<String, dynamic>> status() async {
    try {
      final response = await _channel.invokeMethod<Object?>('status');
      return _normalizeMap(response);
    } on MissingPluginException catch (error) {
      return {
        'ok': false,
        'protocolVersion': 'licolite.secure-mesh.v1',
        'endpointKind': 'mobile',
        'platform': 'android',
        'code': 'secure_mesh_android_bridge_unavailable',
        'error': error.message ?? 'Secure Mesh Android bridge is unavailable.',
        'productionReady': false,
      };
    }
  }

  Future<Map<String, dynamic>> writeRuntimeStatus() async {
    try {
      final response = await _channel.invokeMethod<Object?>(
        'writeRuntimeStatus',
      );
      return _normalizeMap(response);
    } on MissingPluginException catch (error) {
      return {
        'ok': false,
        'protocolVersion': 'licolite.secure-mesh.v1',
        'endpointKind': 'mobile',
        'platform': 'android',
        'code': 'secure_mesh_android_bridge_unavailable',
        'error': error.message ?? 'Secure Mesh Android bridge is unavailable.',
        'productionReady': false,
      };
    }
  }

  Future<Map<String, dynamic>> writeInteropProof() async {
    try {
      final response = await _channel.invokeMethod<Object?>(
        'writeInteropProof',
      );
      return _normalizeMap(response);
    } on MissingPluginException catch (error) {
      return {
        'ok': false,
        'protocolVersion': 'licolite.secure-mesh.v1',
        'endpointKind': 'mobile',
        'platform': 'android',
        'code': 'secure_mesh_android_bridge_unavailable',
        'error': error.message ?? 'Secure Mesh Android bridge is unavailable.',
        'productionReady': false,
      };
    }
  }
}

Map<String, dynamic> _normalizeMap(Object? value) {
  if (value is! Map) {
    return const {};
  }
  return value.map(
    (key, nested) => MapEntry(key.toString(), _normalizeValue(nested)),
  );
}

Object? _normalizeValue(Object? value) {
  if (value is Map) {
    return _normalizeMap(value);
  }
  if (value is List) {
    return value.map(_normalizeValue).toList(growable: false);
  }
  return value;
}
