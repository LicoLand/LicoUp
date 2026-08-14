import 'dart:io';

import 'package:licoup/src/contracts/client_process_lifecycle.dart';

export 'package:licoup/src/contracts/client_process_lifecycle.dart';

final class NativeClientProcessLifecycle implements ClientProcessLifecycle {
  const NativeClientProcessLifecycle();

  @override
  void exitSuccess() => exit(0);
}
