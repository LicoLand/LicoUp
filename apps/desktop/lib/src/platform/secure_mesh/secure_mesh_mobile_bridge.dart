import 'package:flutter/services.dart';
import 'package:flutter_client/src/contracts/generated/secure_mesh.g.dart';

class SecureMeshMobileBridge {
  const SecureMeshMobileBridge({
    required MethodChannel channel,
    required String platform,
    required String unavailableCode,
    required String unavailableMessage,
  }) : _channel = channel,
       _platform = platform,
       _unavailableCode = unavailableCode,
       _unavailableMessage = unavailableMessage;

  final MethodChannel _channel;
  final String _platform;
  final String _unavailableCode;
  final String _unavailableMessage;

  Future<SecureMeshResult> execute(SecureMeshRequest request) async {
    try {
      final response = await _channel.invokeMethod<Object?>(
        'nativeJson',
        request.toJson(),
      );
      return SecureMeshResult.fromJson(
        Map<String, Object?>.from(_normalizeMap(response)),
      );
    } on SecureMeshFailure {
      rethrow;
    } on MissingPluginException {
      throw const SecureMeshFailure(
        code: SecureMeshFailureCode.nativeOperationFailed,
      );
    } on PlatformException {
      throw const SecureMeshFailure(
        code: SecureMeshFailureCode.nativeOperationFailed,
      );
    }
  }

  Future<Map<String, dynamic>> status() async {
    try {
      final response = await _channel.invokeMethod<Object?>('status');
      return _normalizeMap(response);
    } on MissingPluginException catch (error) {
      return _unavailable(error);
    }
  }

  Future<Map<String, dynamic>> writeRuntimeStatus() async {
    try {
      final response = await _channel.invokeMethod<Object?>(
        'writeRuntimeStatus',
      );
      return _normalizeMap(response);
    } on MissingPluginException catch (error) {
      return _unavailable(error);
    }
  }

  Future<Map<String, dynamic>> nativeJson(Map<String, dynamic> request) async {
    try {
      final response = await _channel.invokeMethod<Object?>(
        'nativeJson',
        request,
      );
      return _normalizeMap(response);
    } on MissingPluginException catch (error) {
      return _unavailable(error);
    }
  }

  Map<String, dynamic> _unavailable(MissingPluginException error) {
    return {
      'ok': false,
      'protocolVersion': 'licomesh.secure-mesh.v1',
      'endpointKind': 'mobile',
      'platform': _platform,
      'code': _unavailableCode,
      'error': error.message ?? _unavailableMessage,
      'productionReady': false,
    };
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
