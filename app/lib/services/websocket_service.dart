import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketService {
  WebSocketChannel? _channel;
  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  bool _isConnected = false;
  Timer? _reconnectTimer;

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  bool get isConnected => _isConnected;

  void connect({String baseUrl = 'ws://10.0.2.2:3005'}) {
    if (_isConnected) return;

    try {
      _channel = WebSocketChannel.connect(Uri.parse('$baseUrl/ws'));
      _isConnected = true;

      _channel!.stream.listen(
        (data) {
          try {
            final message = jsonDecode(data as String) as Map<String, dynamic>;
            _messageController.add(message);
          } catch (_) {}
        },
        onDone: () {
          _isConnected = false;
          _scheduleReconnect(baseUrl);
        },
        onError: (_) {
          _isConnected = false;
          _scheduleReconnect(baseUrl);
        },
      );
    } catch (_) {
      _scheduleReconnect(baseUrl);
    }
  }

  void _scheduleReconnect(String baseUrl) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      connect(baseUrl: baseUrl);
    });
  }

  void send(Map<String, dynamic> data) {
    if (_isConnected && _channel != null) {
      _channel!.sink.add(jsonEncode(data));
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _isConnected = false;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}
