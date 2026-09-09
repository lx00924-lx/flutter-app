import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/app_settings.dart';

class LocalAgentService {
  WebSocketChannel? _channel;
  bool isConnected = false;
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  Future<void> connect(AppSettings settings) async {
    try {
      final uri = Uri.parse(settings.localBridgeWsUrl);
      _channel = WebSocketChannel.connect(uri);
      isConnected = true;

      // 发送鉴权握手
      _channel?.sink.add(json.encode({
        'type': 'auth',
        'token': settings.localAgentToken,
        'workspace': settings.targetWorkspace,
      }));

      _channel?.stream.listen(
        (data) {
          try {
            final decoded = json.decode(data.toString());
            _messageController.add(decoded);
          } catch (_) {}
        },
        onDone: () {
          isConnected = false;
        },
        onError: (err) {
          isConnected = false;
        },
      );
    } catch (_) {
      isConnected = false;
    }
  }

  void sendCommand(String command, {Map<String, dynamic>? args}) {
    if (!isConnected || _channel == null) return;
    _channel?.sink.add(json.encode({
      'type': 'command',
      'command': command,
      'args': args ?? {},
    }));
  }

  void disconnect() {
    _channel?.sink.close();
    isConnected = false;
  }
}
