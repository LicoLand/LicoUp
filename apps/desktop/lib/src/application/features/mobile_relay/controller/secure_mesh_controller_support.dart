import 'package:licoup/src/contracts/mobile_relay_control.dart';

final class SecureMeshStatusReporter {
  const SecureMeshStatusReporter(this._sink);

  final MobileRelayFeatureStatusSink _sink;

  void call(String chinese, String english, {String errorCode = ''}) {
    _sink(
      MobileRelayFeatureStatus(
        chinese: chinese,
        english: english,
        caption: 'Secure Mesh',
        errorCode: errorCode,
      ),
    );
  }
}

final class SecureMeshPolicyFailure implements Exception {
  const SecureMeshPolicyFailure();
}

Object? secureMeshNested(
  Map<String, dynamic> value,
  String parent,
  String child,
) {
  final nested = value[parent];
  return nested is Map ? nested[child] : null;
}
