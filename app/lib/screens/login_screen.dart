import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:provider/provider.dart';
import '../providers/game_provider.dart';
import '../services/auth_service.dart';
import 'map_screen.dart';

/// Was der Bildschirm gerade tut. Der Unterschied zwischen [restoring] und
/// [signedOut] ist der Kern dieses Bildschirms: solange die stille
/// Wiederanmeldung laeuft, waere ein Anmeldeknopf eine Luege — er wuerde bei
/// jedem Start aufblitzen, obwohl ihn niemand druecken muss.
enum _AuthStatus { restoring, signedOut, signingIn }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  _AuthStatus _status = _AuthStatus.restoring;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    try {
      // initialize() gilt einmal pro Prozess, das Abonnement dagegen für jeden
      // Aufbau dieses Bildschirms — sonst hätte ein zweiter Aufbau keinen
      // Listener mehr.
      await AuthService.initialize();
    } catch (e) {
      _signInFailed(e);
      return;
    }

    if (!mounted) return;

    // Auf allen Plattformen die einzige Stelle, die eine Anmeldung verarbeitet.
    // Der Android-Plugin liefert keinen eigenen Ereignisstrom, also erzeugt das
    // Paket die Ereignisse selbst — jede Anmeldung kommt hier an, ob sie still
    // oder ueber den Knopf zustande kam. Wuerde zusaetzlich der Rueckgabewert
    // von authenticate() verarbeitet, liefe dieselbe Anmeldung doppelt durch.
    _authSubscription = AuthService.authenticationEvents.listen(
      (event) {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          _handleSignIn(event.user);
        }
      },
      onError: _signInFailed,
    );

    // Stille Wiederanmeldung: stellt eine bestehende Google-Sitzung wieder her,
    // ohne dass jemand etwas druecken muss.
    final Future<GoogleSignInAccount?>? attempt =
        AuthService.attemptLightweight();

    if (attempt == null) {
      // Web/FedCM meldet nicht, wenn es nichts wiederherzustellen gab. Also den
      // Knopf zeigen; kommt doch noch eine Anmeldung, uebernimmt sie der Strom.
      _setStatus(_AuthStatus.signedOut);
      return;
    }

    try {
      // Bei Erfolg uebernimmt der Ereignisstrom. Hier zaehlt nur der Fall, dass
      // es keine wiederherstellbare Sitzung gab.
      if (await attempt == null) _setStatus(_AuthStatus.signedOut);
    } catch (e) {
      _signInFailed(e);
    }
  }

  Future<void> _handleSignIn(GoogleSignInAccount account) async {
    if (!mounted) return;
    setState(() => _status = _AuthStatus.signingIn);

    try {
      final idToken = account.authentication.idToken;
      if (idToken == null) throw Exception('Failed to get ID token');

      if (!mounted) return;

      final provider = context.read<GameProvider>();
      provider.setAuthToken(idToken);

      // Ein vom Backend abgelehnter Token darf nicht auf der Karte landen.
      if (!await provider.login()) {
        throw Exception(provider.error ?? 'server rejected the token');
      }

      await provider.initialize();

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MapScreen()),
      );
    } catch (e) {
      _signInFailed(e);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _status = _AuthStatus.signingIn);

    try {
      if (AuthService.supportsInteractiveSignIn) {
        // Rueckgabe bewusst ignoriert — die Anmeldung kommt ueber den Strom.
        await AuthService.authenticate();
      } else {
        // Web kennt authenticate() nicht. Der Knopf stoesst denselben stillen
        // Versuch nochmal an, der hier eine Kontoauswahl zeigen darf; das
        // Ergebnis kommt ebenfalls ueber den Strom.
        await AuthService.attemptLightweight();
        _setStatus(_AuthStatus.signedOut);
      }
    } catch (e) {
      _signInFailed(e);
    }
  }

  void _setStatus(_AuthStatus status) {
    if (!mounted) return;
    setState(() => _status = status);
  }

  void _signInFailed(Object error) {
    if (!mounted) return;
    setState(() => _status = _AuthStatus.signedOut);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Login failed: $error')),
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1B5E20), Color(0xFF2E7D32), Color(0xFF388E3C)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.terrain,
                  size: 100,
                  color: Colors.white,
                ),
                const SizedBox(height: 16),
                const Text(
                  'TURF WARS',
                  style: TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Claim your territory',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 64),
                _status != _AuthStatus.signedOut
                    ? const CircularProgressIndicator(color: Colors.white)
                    : ElevatedButton.icon(
                        onPressed: _signInWithGoogle,
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in with Google'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF1B5E20),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
                          ),
                          textStyle: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
