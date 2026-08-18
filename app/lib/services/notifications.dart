import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Lokale Benachrichtigungen für das, was das Gerät beim Gehen selbst
/// feststellt.
///
/// Beim Laufen steckt das Handy in der Tasche — das ist der Normalfall, nicht
/// die Ausnahme. Ohne Meldung merkt man vom Abschluss einer Runde nichts, bis
/// man das nächste Mal hinschaut.
class NotificationService {
  static const String _channelId = 'loop_closed';
  static const String _channelName = 'Geschlossene Runden';

  /// Eine feste ID: eine weitere geschlossene Runde ersetzt die vorige Meldung,
  /// statt sich daneben zu stapeln.
  static const int _loopNotificationId = 1;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> initialize() async {
    if (_ready) return;

    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );

      // Ab Android 13 muss die Berechtigung erfragt werden, darunter gilt sie
      // mit der Installation als erteilt. Ein Nein ist kein Fehler — der Lauf
      // funktioniert weiter, nur eben stumm.
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();

      _ready = true;
    } catch (e) {
      // Eine fehlende Benachrichtigung darf den Start nicht kosten.
      debugPrint('NotificationService.initialize: $e');
    }
  }

  /// Meldet geschlossene, noch unbeantwortete Runden.
  ///
  /// [area] ist die zuletzt geschlossene Runde, [openLoops] die Gesamtzahl der
  /// wartenden. Beim Gehen können mehrere zusammenkommen, bevor jemand
  /// hinschaut.
  Future<void> showLoopClosed({
    required String area,
    required int openLoops,
  }) async {
    if (!_ready) return;

    final body = openLoops > 1
        ? '$openLoops Runden warten auf deine Entscheidung.'
        : 'Du hast $area umrundet. Als Gebiet beanspruchen?';

    try {
      await _plugin.show(
        _loopNotificationId,
        'Runde geschlossen',
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription:
                'Meldet, wenn sich beim Gehen eine Runde schliesst',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.event,
            // Damit der Text auch auf dem gesperrten Bildschirm lesbar ist und
            // nicht nur "Benachrichtigung" dort steht.
            visibility: NotificationVisibility.public,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('NotificationService.showLoopClosed: $e');
    }
  }

  /// Räumt die Meldung weg, sobald keine Runde mehr wartet.
  Future<void> clearLoopClosed() async {
    if (!_ready) return;
    try {
      await _plugin.cancel(_loopNotificationId);
    } catch (e) {
      debugPrint('NotificationService.clearLoopClosed: $e');
    }
  }
}
