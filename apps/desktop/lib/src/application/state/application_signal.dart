import 'dart:async';

typedef ApplicationCallback = void Function();
typedef ApplicationDiagnosticSink = void Function(String code);

final class ApplicationCause {
  const ApplicationCause({this.traceId});

  final String? traceId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplicationCause && other.traceId == traceId;

  @override
  int get hashCode => traceId.hashCode;
}

final class ApplicationChange {
  const ApplicationChange({this.cause});

  final ApplicationCause? cause;
}

/// Owner-private synchronous broadcast signal for one Application state owner.
final class ApplicationSignal {
  ApplicationSignal._(this._controller);

  final StreamController<ApplicationChange> _controller;

  Stream<ApplicationChange> get changes => _controller.stream;
}

/// The state-owner half of an [ApplicationSignal]. Renderers and projections
/// receive only [signal], so publication and lifetime stay with the owner.
final class ApplicationSignalOwner {
  ApplicationSignalOwner()
    : _controller = StreamController<ApplicationChange>.broadcast(sync: true) {
    signal = ApplicationSignal._(_controller);
  }

  final StreamController<ApplicationChange> _controller;
  late final ApplicationSignal signal;
  bool _closed = false;

  bool get closed => _closed;

  void publish([ApplicationCause? cause]) {
    if (_closed) return;
    _controller.add(ApplicationChange(cause: cause));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_controller.close());
  }
}

/// Base for framework-independent state owners.
abstract class ApplicationStateOwner {
  final ApplicationSignalOwner _signalOwner = ApplicationSignalOwner();
  bool _applicationStateDisposed = false;

  Stream<ApplicationChange> get changes => _signalOwner.signal.changes;
  bool get applicationStateDisposed => _applicationStateDisposed;

  void publishChange([ApplicationCause? cause]) {
    if (!_applicationStateDisposed) _signalOwner.publish(cause);
  }

  void dispose() {
    if (_applicationStateDisposed) return;
    _applicationStateDisposed = true;
    _signalOwner.close();
  }
}
