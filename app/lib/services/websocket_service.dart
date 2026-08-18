import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_service.dart';

/// Live-Verbindung zum Backend.
///
/// Draussen unterwegs bricht das Netz regelmässig weg, deshalb ist ein
/// Verbindungsfehler hier der Normalfall und kein Ausnahmezustand: es wird
/// still im wachsenden Abstand neu versucht.
class WebSocketService {
  WebSocketChannel? _channel;
  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  bool _isConnected = false;
  Timer? _reconnectTimer;
  int _attempts = 0;
  bool _disposed = false;

  Stream<Map<String, dynamic>> get messages => _messageController.stream;
  bool get isConnected => _isConnected;

  static const Duration _firstDelay = Duration(seconds: 5);
  static const Duration _maxDelay = Duration(minutes: 2);

  Future<void> connect({String? baseUrl}) async {
    if (_disposed || _isConnected) return;

    final wsUrl = baseUrl ?? ApiService.baseUrl.replaceFirst('http', 'ws');

    try {
      final channel = WebSocketChannel.connect(Uri.parse('$wsUrl/ws'));

      // connect() ist lazy — der eigentliche Fehler kommt erst hier. Ohne
      // dieses await landet er als unbehandelte Ausnahme in der Konsole.
      await channel.ready;

      _channel = channel;
      _isConnected = true;
      _attempts = 0;

      channel.stream.listen(
        (data) {
          try {
            final message = jsonDecode(data as String) as Map<String, dynamic>;
            _messageController.add(message);
          } catch (_) {
            // Nachrichten, die wir nicht verstehen, ignorieren wir
          }
        },
        onDone: () => _handleDrop(wsUrl),
        onError: (_) => _handleDrop(wsUrl),
        cancelOnError: true,
      );
    } catch (error) {
      debugPrint('WebSocket nicht erreichbar: $error');
      _handleDrop(wsUrl);
    }
  }

  void _handleDrop(String wsUrl) {
    _isConnected = false;
    _channel = null;
    _scheduleReconnect(wsUrl);
  }

  void _scheduleReconnect(String wsUrl) {
    if (_disposed) return;

    // 5s, 10s, 20s, 40s … höchstens zwei Minuten
    final delay = Duration(
      seconds: (_firstDelay.inSeconds * (1 << _attempts))
          .clamp(_firstDelay.inSeconds, _maxDelay.inSeconds),
    );
    _attempts = (_attempts + 1).clamp(0, 5);

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => connect(baseUrl: wsUrl));
  }

  void send(Map<String, dynamic> data) {
    if (_isConnected && _channel != null) {
      _channel!.sink.add(jsonEncode(data));
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _messageController.close();
  }
}
