import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class ApiService {
  static const String _productionUrl = 'https://turf-api.mauch.rocks';

  static String get baseUrl {
    // For local development, uncomment:
    // if (kIsWeb) return 'http://localhost:3005';
    // if (Platform.isAndroid) return 'http://10.0.2.2:3005';
    // return 'http://localhost:3005';
    return _productionUrl;
  }

  /// Injizierbar, damit sich die 401-Wiederholung testen lässt — ohne das
  /// hinge sie an einem echten Server.
  final http.Client _client;

  ApiService({http.Client? client}) : _client = client ?? http.Client();

  String? _authToken;

  /// Wird gerufen, wenn der Server den Token ablehnt. Liefert einen frischen
  /// oder null, wenn keine Sitzung mehr da ist.
  ///
  /// Als Rückruf und nicht als direkter Aufruf, damit die Netzwerkschicht
  /// nichts von google_sign_in wissen muss.
  Future<String?> Function()? onTokenRejected;

  Future<String?>? _refreshInFlight;

  void setAuthToken(String token) {
    _authToken = token;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(
        queryParameters: (query == null || query.isEmpty) ? null : query,
      );

  /// Führt [send] aus und wiederholt **genau einmal** mit frischem Token, wenn
  /// der Server mit 401 antwortet.
  ///
  /// Der ID-Token ist rund eine Stunde gültig, ein Lauf dauert länger. Ohne das
  /// hier schlagen ab dann alle Aufrufe fehl, während die App weiterhin
  /// angemeldet aussieht. Nur einmal wiederholen: lehnt der Server auch den
  /// frischen Token ab, liegt es nicht am Ablauf und ein zweiter Versuch würde
  /// sich nur im Kreis drehen.
  Future<http.Response> _authed(
    Future<http.Response> Function(Map<String, String> headers) send,
  ) async {
    final response = await send(_headers);
    if (response.statusCode != 401 || onTokenRejected == null) return response;

    final fresh = await _refreshToken();
    if (fresh == null) return response;

    _authToken = fresh;
    return send(_headers);
  }

  /// Erneuert höchstens einmal gleichzeitig.
  ///
  /// Nach dem Ablauf laufen mehrere Aufrufe nebeneinander in den 401 — Karte,
  /// Stats und Rankings zum Beispiel. Ohne diese Sperre gäbe es ebenso viele
  /// parallele Anmeldeversuche.
  Future<String?> _refreshToken() {
    return _refreshInFlight ??= onTokenRejected!().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<http.Response> _get(Uri uri) =>
      _authed((headers) => _client.get(uri, headers: headers));

  Future<http.Response> _post(Uri uri, {Object? body}) => _authed(
        (headers) => _client.post(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
      );

  // Auth
  /// Bewusst am 401-Handler vorbei: hier wird die Sitzung gerade erst
  /// aufgebaut. Lehnt der Server diesen Token ab, brächte eine Erneuerung
  /// denselben zurück.
  Future<Map<String, dynamic>> login() async {
    final response = await _client
        .post(_uri('/auth/login'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getMe() async {
    final response = await _get(_uri('/auth/me'));
    return jsonDecode(response.body);
  }

  // Territories
  Future<Map<String, dynamic>> claimTerritory(
    List<LatLng> coordinates, {
    Map<String, dynamic>? walkStats,
  }) async {
    final body = <String, dynamic>{
      'coordinates': coordinates.map((c) => [c.longitude, c.latitude]).toList(),
    };
    if (walkStats != null) {
      body['walkStats'] = walkStats;
    }

    final response = await _post(_uri('/territories/claim'), body: body);
    return jsonDecode(response.body);
  }

  /// [bounds] is "minLng,minLat,maxLng,maxLat". Without it the server answers
  /// with every active territory worldwide, which is only tolerable while the
  /// map has not settled on a viewport yet.
  Future<List<dynamic>> getTerritories({
    String? regionId,
    String? bounds,
  }) async {
    final response = await _get(_uri('/territories', {
      'region_id': ?regionId,
      'bounds': ?bounds,
    }));
    final data = jsonDecode(response.body);
    return data['territories'] ?? [];
  }

  Future<Map<String, dynamic>> getStats() async {
    final response = await _get(_uri('/territories/stats'));
    return jsonDecode(response.body);
  }

  Future<List<dynamic>> getMyTerritories() async {
    final response = await _get(_uri('/territories/mine'));
    final data = jsonDecode(response.body);
    return data['territories'] ?? [];
  }

  // Rankings
  Future<List<dynamic>> getRankings(String regionId, {int limit = 50}) async {
    final response = await _get(
      _uri('/rankings/$regionId', {'limit': '$limit'}),
    );
    final data = jsonDecode(response.body);
    return data['rankings'] ?? [];
  }

  Future<Map<String, dynamic>?> locateMunicipality(
    double lat,
    double lng,
  ) async {
    final response = await _get(_uri('/rankings/regions/locate', {
      'lat': '$lat',
      'lng': '$lng',
    }));
    final data = jsonDecode(response.body);
    return data['municipality'];
  }

  // Dev endpoints
  Future<List<dynamic>> getDevUsers() async {
    final response = await _get(_uri('/territories/dev/users'));
    final data = jsonDecode(response.body);
    return data['users'] ?? [];
  }

  Future<Map<String, dynamic>> devPlaceTerritory(
    String userId,
    List<LatLng> coordinates, {
    Map<String, dynamic>? walkStats,
  }) async {
    final body = <String, dynamic>{
      'userId': userId,
      'coordinates': coordinates.map((c) => [c.longitude, c.latitude]).toList(),
    };
    if (walkStats != null) {
      body['walkStats'] = walkStats;
    }

    final response = await _post(_uri('/territories/dev/place'), body: body);
    return jsonDecode(response.body);
  }
}
