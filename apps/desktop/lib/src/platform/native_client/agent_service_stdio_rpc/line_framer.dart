import 'dart:typed_data';

typedef StdioRpcFrameCallback = void Function(Uint8List bytes);
typedef StdioRpcOversizedFrameCallback = void Function();

class StdioRpcLineFramer {
  StdioRpcLineFramer({required this.maxFrameBytes});

  final int maxFrameBytes;
  final BytesBuilder _currentFrame = BytesBuilder(copy: false);
  var _currentFrameBytes = 0;
  var _discardingOversizedFrame = false;

  void accept(
    List<int> chunk, {
    required StdioRpcFrameCallback onFrame,
    required StdioRpcOversizedFrameCallback onOversizedFrame,
  }) {
    var start = 0;
    for (var index = 0; index < chunk.length; index += 1) {
      if (chunk[index] != 0x0a) {
        continue;
      }
      _append(chunk, start, index);
      _finish(onFrame, onOversizedFrame);
      start = index + 1;
    }
    _append(chunk, start, chunk.length);
  }

  void _append(List<int> chunk, int start, int end) {
    if (start >= end || _discardingOversizedFrame) {
      return;
    }
    final length = end - start;
    if (_currentFrameBytes + length + 1 > maxFrameBytes) {
      _discardingOversizedFrame = true;
      _currentFrame.clear();
      _currentFrameBytes = 0;
      return;
    }
    _currentFrame.add(chunk.sublist(start, end));
    _currentFrameBytes += length;
  }

  void _finish(
    StdioRpcFrameCallback onFrame,
    StdioRpcOversizedFrameCallback onOversizedFrame,
  ) {
    if (_discardingOversizedFrame) {
      _discardingOversizedFrame = false;
      onOversizedFrame();
      return;
    }
    var bytes = _currentFrame.takeBytes();
    _currentFrameBytes = 0;
    if (bytes.isNotEmpty && bytes.last == 0x0d) {
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    onFrame(bytes);
  }
}
