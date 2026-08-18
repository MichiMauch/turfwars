import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:turf_wars/services/api_service.dart';

/// Ein Server, der jeden Token ausser [validToken] mit 401 abweist — so
/// verhält sich das Backend, wenn der ID-Token nach rund einer Stunde abläuft.
class _FakeServer {
  _FakeServer(this.validToken);

  String validToken;
  int requests = 0;

  /// Hält jede Antwort auf, bis [release] gerufen wird. Damit lässt sich der
  /// Fall nachstellen, dass mehrere Aufrufe gleichzeitig in den 401 laufen.
  Completer<void>? gate;

  void release() {
    gate?.complete();
    gate = null;
  }

  http.Client get client => MockClient((request) async {
        requests++;
        if (gate != null) await gate!.future;

        final sent = request.headers['Authorization'];
        if (sent != 'Bearer $validToken') {
          return http.Response(jsonEncode({'error': 'Invalid token'}), 401);
        }
        return http.Response(jsonEncode({'territories': []}), 200);
      });
}

void main() {
  group('401-Wiederholung', () {
    test('holt einen frischen Token und wiederholt den Aufruf', () async {
      final server = _FakeServer('neu');
      var refreshes = 0;

      final api = ApiService(client: server.client)
        ..setAuthToken('abgelaufen')
        ..onTokenRejected = () async {
          refreshes++;
          return 'neu';
        };

      await api.getTerritories();

      expect(refreshes, 1);
      // Einmal mit dem abgelaufenen, einmal mit dem frischen Token.
      expect(server.requests, 2);
    });

    test('wiederholt genau einmal, auch wenn es wieder 401 gibt', () async {
      final server = _FakeServer('niemals');
      var refreshes = 0;

      final api = ApiService(client: server.client)
        ..setAuthToken('abgelaufen')
        ..onTokenRejected = () async {
          refreshes++;
          return 'auch-falsch';
        };

      await api.getTerritories();

      // Sonst dreht sich das im Kreis, wenn der Server aus einem anderen
      // Grund ablehnt als dem Ablauf.
      expect(refreshes, 1);
      expect(server.requests, 2);
    });

    test('erneuert nur einmal, wenn mehrere Aufrufe gleichzeitig scheitern',
        () async {
      final server = _FakeServer('neu')..gate = Completer<void>();
      var refreshes = 0;

      final api = ApiService(client: server.client)
        ..setAuthToken('abgelaufen')
        ..onTokenRejected = () async {
          refreshes++;
          return 'neu';
        };

      // Karte, Stats und Rankings laufen nach dem Ablauf nebeneinander rein.
      final calls = Future.wait([
        api.getTerritories(),
        api.getStats(),
        api.getRankings('municipality-1'),
      ]);

      // Erst jetzt antwortet der Server — alle drei stehen im 401.
      server.release();
      await calls;

      expect(refreshes, 1);
    });

    test('lässt den 401 stehen, wenn sich kein Token mehr holen lässt',
        () async {
      final server = _FakeServer('neu');
      var refreshes = 0;

      final api = ApiService(client: server.client)
        ..setAuthToken('abgelaufen')
        ..onTokenRejected = () async {
          refreshes++;
          return null; // keine Sitzung mehr
        };

      final result = await api.getTerritories();

      expect(refreshes, 1);
      // Kein zweiter Versuch — ohne Token wäre er sinnlos.
      expect(server.requests, 1);
      expect(result, isEmpty);
    });

    test('fasst einen erfolgreichen Aufruf nicht an', () async {
      final server = _FakeServer('gueltig');
      var refreshes = 0;

      final api = ApiService(client: server.client)
        ..setAuthToken('gueltig')
        ..onTokenRejected = () async {
          refreshes++;
          return 'neu';
        };

      await api.getTerritories();

      expect(refreshes, 0);
      expect(server.requests, 1);
    });

    test('erneuert nach einem späteren Ablauf erneut', () async {
      final server = _FakeServer('zweiter');
      var refreshes = 0;

      final api = ApiService(client: server.client)
        ..setAuthToken('abgelaufen')
        ..onTokenRejected = () async {
          refreshes++;
          return 'zweiter';
        };

      await api.getTerritories();
      expect(refreshes, 1);

      // Der nächste Ablauf, später in derselben Sitzung.
      server.validToken = 'dritter';
      api.onTokenRejected = () async {
        refreshes++;
        return 'dritter';
      };
      await api.getTerritories();

      // Die Sperre darf nicht kleben bleiben, sonst gäbe es nie eine zweite
      // Erneuerung.
      expect(refreshes, 2);
    });
  });
}
