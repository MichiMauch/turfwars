import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

const String _webClientId =
    '239062108739-l2s28bkfqga6so33lvdc9pa4ditbdmvf.apps.googleusercontent.com';

/// Alles rund um die Google-Anmeldung an einer Stelle.
///
/// Nicht nur der Anmeldebildschirm braucht das. Der ID-Token ist rund eine
/// Stunde gültig und ein Lauf dauert länger — läuft er ab, muss die
/// Netzwerkschicht still einen neuen holen können, ohne dass jemand zurück
/// zum Anmeldebildschirm muss.
class AuthService {
  static bool _initialized = false;

  /// Einmal je Prozess. Mehrfach aufrufbar, spätere Aufrufe tun nichts.
  static Future<void> initialize() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(
      clientId: kIsWeb ? _webClientId : null,
      serverClientId: kIsWeb ? null : _webClientId,
    );
    _initialized = true;
  }

  static Stream<GoogleSignInAuthenticationEvent> get authenticationEvents =>
      GoogleSignIn.instance.authenticationEvents;

  /// Stösst eine stille Wiederanmeldung an.
  ///
  /// Liefert das Future der Plattform, oder null wenn sie keines liefert —
  /// Web/FedCM meldet ausschliesslich über [authenticationEvents].
  static Future<GoogleSignInAccount?>? attemptLightweight() =>
      GoogleSignIn.instance.attemptLightweightAuthentication();

  static bool get supportsInteractiveSignIn =>
      GoogleSignIn.instance.supportsAuthenticate();

  static Future<void> authenticate() => GoogleSignIn.instance.authenticate();

  /// Holt einen frischen ID-Token für eine bestehende Sitzung.
  ///
  /// Ein zwischengespeichertes Konto hilft nicht: `account.authentication`
  /// liefert die Token vom Zeitpunkt der Anmeldung. Es braucht eine neue
  /// stille Anmeldung.
  ///
  /// null heisst: keine Sitzung mehr da — oder Web, wo die Plattform kein
  /// Future liefert und das Ergebnis nur über den Ereignisstrom kommt. Beides
  /// bedeutet für den Aufrufer dasselbe: hier geht es nicht still weiter.
  static Future<String?> refreshIdToken() async {
    try {
      await initialize();
      final attempt = attemptLightweight();
      if (attempt == null) return null;

      final account = await attempt;
      return account?.authentication.idToken;
    } catch (e) {
      debugPrint('AuthService.refreshIdToken: $e');
      return null;
    }
  }
}
