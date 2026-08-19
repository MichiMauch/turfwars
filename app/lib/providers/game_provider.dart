import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/territory.dart';
import '../utils/format.dart';
import '../utils/geo.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
import '../services/notifications.dart';
import '../services/pending_loop.dart';
import '../services/walk_simulator.dart';
import '../services/websocket_service.dart';

class GameProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final LocationService _location = LocationService();
  final WebSocketService _ws = WebSocketService();
  late final WalkSimulator _walkSimulator = WalkSimulator(_location);

  // State
  List<Territory> _territories = [];
  List<RankingEntry> _rankings = [];
  List<LatLng> _currentTrack = [];
  TrackingStatus _trackingStatus = TrackingStatus.stopped;
  bool _isLoading = false;
  /// Fehler einer Aktion, die der Spieler ausgelöst hat — der gehört gross
  /// angezeigt. Nachladefehler stehen bewusst getrennt, sonst widerspricht
  /// ein abgebrochener Refresh der Erfolgsmeldung eines Claims.
  String? _error;
  String? _loadError;
  String? _userId;
  String? _displayName;
  String? _avatarUrl;
  String? _myColor;

  /// Ob dieses Konto in DEV_ADMIN_ACCOUNTS steht. Kommt vom Server, weil dort
  /// dieselbe Liste die Dev-Endpunkte schützt — zwei Quellen dafür wären eine
  /// zuviel.
  bool _isDevAdmin = false;

  /// Ob die Werkzeuge gerade angezeigt werden. Getrennt von [_isDevAdmin],
  /// damit man die Ansicht eines normalen Spielers sehen kann, ohne die
  /// Berechtigung zu verlieren.
  bool _showDevTools = true;
  LatLng? _currentPosition;
  String? _selectedRegionId;
  AdminRegion? _currentMunicipality;
  bool _municipalityDetected = false;
  /// Verhindert, dass derselbe geschlossene Loop zweimal weggeschnappt wird —
  /// der Statusstrom und stopTracking() können beide darauf zeigen.
  bool _closingLoop = false;
  final NotificationService _notifications = NotificationService();
  final PendingLoopStore _pendingLoopStore = PendingLoopStore();
  List<PendingLoop> _pendingLoops = [];
  Territory? _lastClaimedTerritory;
  PlayerStats? _stats;
  String? _simulatedUserId;
  String? _simulatedUserName;

  /// Zuletzt geladener Kartenausschnitt als "minLng,minLat,maxLng,maxLat".
  /// Gemerkt, damit auch das Nachladen nach einem Claim auf den Ausschnitt
  /// beschränkt bleibt, statt wieder die ganze Welt anzufragen.
  String? _visibleBounds;

  /// Derselbe Kasten als Zahlen, um zu erkennen ob ein neuer Ausschnitt schon
  /// darin liegt.
  BoundsBox? _loadedBounds;

  /// Die Laufzeit ändert sich auch ohne neuen GPS-Punkt — ohne eigenen Takt
  /// stünde die Uhr still, sobald jemand stehen bleibt.
  Timer? _ticker;

  // Getters
  List<Territory> get territories => _territories;
  List<RankingEntry> get rankings => _rankings;
  List<LatLng> get currentTrack => _currentTrack;
  TrackingStatus get trackingStatus => _trackingStatus;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get loadError => _loadError;
  String? get userId => _userId;
  String? get displayName => _displayName;
  String? get avatarUrl => _avatarUrl;
  String? get myColor => _myColor;
  bool get isDevAdmin => _isDevAdmin;

  /// Ob die Entwicklerwerkzeuge sichtbar sind. Beides muss zutreffen.
  bool get devToolsVisible => _isDevAdmin && _showDevTools;
  bool get showDevTools => _showDevTools;

  static const String _showDevToolsKey = 'show_dev_tools';

  Future<void> setShowDevTools(bool value) async {
    _showDevTools = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showDevToolsKey, value);
  }
  LatLng? get currentPosition => _currentPosition;
  String? get selectedRegionId => _selectedRegionId;
  AdminRegion? get currentMunicipality => _currentMunicipality;
  bool get municipalityDetected => _municipalityDetected;
  /// Geschlossene Runden, die auf eine Entscheidung warten — älteste zuerst.
  List<PendingLoop> get pendingLoops => List.unmodifiable(_pendingLoops);
  Territory? get lastClaimedTerritory => _lastClaimedTerritory;
  PlayerStats? get stats => _stats;
  String? get simulatedUserId => _simulatedUserId;
  String? get simulatedUserName => _simulatedUserName;
  bool get isTracking => _location.isTracking;
  double get currentSpeedKmh => _location.currentSpeedMs * 3.6;
  // Die Anzeige zeigt den ganzen Lauf. Die Werte der einzelnen Runde gehen
  // über _buildWalkStats ans Gebiet und stehen nicht auf dem Bildschirm.
  double get totalDistanceM => _location.walkDistanceM;
  int get durationSec => _location.walkDurationSec;
  LocationService get locationService => _location;

  GameProvider() {
    // Der ID-Token ist rund eine Stunde gültig, ein Lauf dauert länger. Der
    // ApiService holt sich über diesen Rückruf still einen neuen, statt ab
    // dann jeden Aufruf scheitern zu lassen.
    _api.onTokenRejected = _refreshAuthToken;

    _location.trackStream.listen((track) {
      _currentTrack = track;
      // Der Standort wurde bisher nur einmal beim Start gesetzt — der blaue
      // Punkt zeigte die ganze Sitzung über die Position vom App-Start. Die
      // Punkte kommen ohnehin hier an, ein zweiter GPS-Stream wäre unnötig.
      if (track.isNotEmpty) _currentPosition = track.last;
      notifyListeners();
    });

    _location.statusStream.listen((status) {
      _trackingStatus = status;
      notifyListeners();

      // Loop geschlossen: wegschnappen und nachfragen, nicht beanspruchen
      if (status == TrackingStatus.loopDetected && !_closingLoop) {
        _closeLoop();
      }
    });

    _ws.messages.listen(_handleWebSocketMessage);
  }

  void setAuthToken(String token) {
    _api.setAuthToken(token);
    _sessionExpired = false;
  }

  /// Die Sitzung liess sich nicht mehr erneuern — es hilft nur neu anmelden.
  bool _sessionExpired = false;
  bool get sessionExpired => _sessionExpired;

  void clearSessionExpired() {
    _sessionExpired = false;
  }

  Future<String?> _refreshAuthToken() async {
    final token = await AuthService.refreshIdToken();
    if (token == null) {
      _sessionExpired = true;
      notifyListeners();
    }
    return token;
  }

  /// Meldet den bereits gesetzten Token am Backend an. Gibt zurueck, ob das
  /// geklappt hat — ein abgelehnter Token darf den Anmeldebildschirm nicht
  /// verlassen, sonst sieht die App angemeldet aus und kein Aufruf funktioniert.
  Future<bool> login() async {
    try {
      final result = await _api.login();
      final user = result['user'];
      if (user == null) {
        throw Exception(result['error'] ?? 'no user in response');
      }
      _userId = user['id'];
      _displayName = user['displayName'];
      _avatarUrl = user['avatarUrl'];
      _myColor = user['color'];
      _isDevAdmin = result['isDevAdmin'] == true;
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Login failed: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> initialize() async {
    // Die Wahl der Ansicht überlebt den Neustart — wer die Spieleransicht
    // eingeschaltet hat, will sie nicht jedes Mal neu wählen.
    final prefs = await SharedPreferences.getInstance();
    _showDevTools = prefs.getBool(_showDevToolsKey) ?? true;

    // Runden, die beim letzten Mal unbeantwortet blieben. Abgelaufene sortiert
    // der Speicher selbst aus.
    _pendingLoops = await _pendingLoopStore.load();
    if (_pendingLoops.isNotEmpty) notifyListeners();

    await _notifications.initialize();

    final hasPermission = await _location.checkPermissions();
    if (!hasPermission) {
      _error = 'Location permission required';
      notifyListeners();
      return;
    }

    // Erst die zuletzt bekannte Position — die gibt es sofort und die Karte
    // steht damit an der richtigen Stelle, statt in Zürich. Der genaue Fix
    // zieht gleich nach.
    _currentPosition = await _location.getLastKnownPosition();
    if (_currentPosition != null) notifyListeners();

    // Connect WebSocket
    _ws.connect();

    // Load territories immediately. Ohne Ausschnitt fragt der erste Aufruf
    // jedes Gebiet weltweit an — die Karte startet ohnehin beim Standort, also
    // gleich von dort aus einen groben Kasten laden. Die Karte ersetzt ihn,
    // sobald sie ihren tatsächlichen Ausschnitt kennt.
    final start = _currentPosition;
    if (start != null) {
      const startBoxDeg = 0.05; // rund 5 km
      await loadTerritoriesIn(
        minLng: start.longitude - startBoxDeg,
        minLat: start.latitude - startBoxDeg,
        maxLng: start.longitude + startBoxDeg,
        maxLat: start.latitude + startBoxDeg,
      );
    } else {
      await loadTerritories();
    }

    // Der genaue Fix. Er darf jetzt dauern — niemand wartet mehr darauf.
    final exact = await _location.getCurrentPosition();
    if (exact != null) {
      _currentPosition = exact;
      notifyListeners();
    }

    // Locate municipality from GPS
    if (_currentPosition != null) {
      await _detectMunicipality();
    }

    // Everything the ranking and stats screens need is derived from where
    // the player stands and what they hold — no confirmation required.
    await loadStats();
    final here = rankingRegions;
    if (here.isNotEmpty) {
      await loadRankings(here.first.id);
    }
  }

  static const List<String> levelOrder = [
    'municipality',
    'district',
    'canton',
    'country',
  ];

  /// One region per level worth ranking: the municipality the player is
  /// standing in, plus the largest holding on every other level.
  List<RegionHolding> get rankingRegions {
    final byLevel = <String, RegionHolding>{};

    // stats.regions is sorted by area, so the first hit per level is the
    // one where the player holds the most ground
    for (final region in _stats?.regions ?? const <RegionHolding>[]) {
      byLevel.putIfAbsent(region.level, () => region);
    }

    // Where you are beats where you own most — you play here, now
    final here = _currentMunicipality;
    if (here != null) {
      byLevel['municipality'] = _holdingFor(here.id) ??
          RegionHolding(
            id: here.id,
            name: here.name,
            level: 'municipality',
            areaSqm: 0,
          );
    }

    return [
      for (final level in levelOrder)
        if (byLevel[level] != null) byLevel[level]!,
    ];
  }

  RegionHolding? _holdingFor(String regionId) {
    for (final region in _stats?.regions ?? const <RegionHolding>[]) {
      if (region.id == regionId) return region;
    }
    return null;
  }

  Future<void> _detectMunicipality() async {
    if (_currentPosition == null) return;

    try {
      final data = await _api.locateMunicipality(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
      if (data != null) {
        _currentMunicipality = AdminRegion.fromJson(data);
      } else {
        _currentMunicipality = null;
      }
    } catch (e) {
      _currentMunicipality = null;
    }
    _municipalityDetected = true;
    notifyListeners();
  }

  /// Übernimmt den sichtbaren Kartenausschnitt und lädt die Gebiete darin. Der
  /// Ausschnitt wird um ein Viertel seiner Kantenlänge geweitet, damit ein
  /// kleines Verschieben nicht sofort einen leeren Rand zeigt.
  /// Ändert die eigene Spielerfarbe und lädt die Gebiete neu, damit die
  /// eigenen sofort umgefärbt sind.
  Future<bool> setMyColor(String hex) async {
    final previous = _myColor;
    _myColor = hex;
    notifyListeners();

    try {
      final result = await _api.setMyColor(hex);
      if (result.containsKey('error')) {
        // Der Server ist die einzige Instanz, die entscheidet was gültig ist.
        _myColor = previous;
        _error = result['error'];
        notifyListeners();
        return false;
      }
      // Direkt und nicht über loadTerritoriesIn: der Ausschnitt hat sich nicht
      // geändert, die Prüfung dort würde das Nachladen überspringen.
      await loadTerritories();
      return true;
    } catch (e) {
      _myColor = previous;
      _error = 'Farbe konnte nicht gesetzt werden: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> loadTerritoriesIn({
    required double minLng,
    required double minLat,
    required double maxLng,
    required double maxLat,
  }) {
    // Liegt der neue Ausschnitt schon im geladenen Kasten, gibt es nichts zu
    // holen. Ohne diese Prüfung stellt das Nachführen während eines Laufs bei
    // jedem GPS-Punkt eine Anfrage — der Rand ist genau dafür da.
    final wanted = BoundsBox(minLng, minLat, maxLng, maxLat);
    if (_loadedBounds?.contains(wanted) ?? false) return Future.value();

    final padded = wanted.padded(0.25);
    _loadedBounds = padded;
    _visibleBounds = padded.asQuery;
    return loadTerritories();
  }

  Future<void> loadTerritories({bool retry = true}) async {
    _isLoading = true;
    notifyListeners();

    try {
      final data = await _api.getTerritories(bounds: _visibleBounds);
      _territories = data.map((t) => Territory.fromJson(t)).toList();
      _loadError = null;
    } catch (e) {
      debugPrint('loadTerritories: $e');
      if (retry) {
        // Unterwegs reisst die Verbindung oft nur kurz ab
        _isLoading = false;
        await Future.delayed(const Duration(seconds: 3));
        return loadTerritories(retry: false);
      }
      _loadError = 'Gebiete konnten nicht geladen werden.';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadStats() async {
    _isLoading = true;
    notifyListeners();

    try {
      final data = await _api.getStats();
      if (data.containsKey('error')) {
        _loadError = data['error'];
      } else {
        _stats = PlayerStats.fromJson(data);
        _loadError = null;
      }
    } catch (e) {
      debugPrint('loadStats: $e');
      _loadError = 'Statistik konnte nicht geladen werden.';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadRankings(String regionId) async {
    _selectedRegionId = regionId;
    _isLoading = true;
    notifyListeners();

    try {
      final data = await _api.getRankings(regionId);
      _rankings = data.map((r) => RankingEntry.fromJson(r)).toList();
      _loadError = null;
    } catch (e) {
      debugPrint('loadRankings: $e');
      _loadError = 'Rangliste konnte nicht geladen werden.';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> startTracking() async {
    _error = null;
    _loadError = null;
    _lastClaimedTerritory = null;
    _startTicker();
    await _location.startTracking();
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_location.isTracking) {
        notifyListeners();
      } else {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  Future<void> stopTracking() async {
    // Get fresh GPS position before stopping — distanceFilter may have
    // prevented the last position update, so _track.last could be stale
    final currentPos = await _location.getCurrentPosition();
    if (currentPos != null && _location.track.isNotEmpty) {
      _location.addPoint(currentPos);
    }

    // Check for closed loop before stopping (GPS might not have triggered loopDetected)
    final loopClosed = _location.isLoopClosed();
    debugPrint('STOP: loopClosed=$loopClosed, closingLoop=$_closingLoop');
    if (loopClosed && !_closingLoop) {
      // Abwarten: der Loop muss weggeschnappt sein, bevor die Spur wegfällt.
      await _closeLoop();
    }
    _location.stopTracking();
  }

  Map<String, dynamic> _buildWalkStats() {
    final trackCoords = _location.track
        .map((p) => [p.longitude, p.latitude])
        .toList();
    return {
      'distanceM': _location.loopDistanceM,
      'durationSec': _location.loopDurationSec,
      'avgSpeedKmh': _location.loopAvgSpeedKmh,
      'maxSpeedKmh': _location.loopMaxSpeedKmh,
      'trackPointCount': _location.track.length,
      'trackCoordinates': trackCoords,
    };
  }

  /// Ein Loop hat sich geschlossen.
  ///
  /// Er wird sofort aus dem LocationService herausgeschnappt und zur
  /// Bestätigung abgelegt, statt beansprucht — und die Aufzeichnung läuft
  /// direkt weiter. Damit lässt sich eine Acht gehen: die erste Runde wartet
  /// auf eine Antwort, während die zweite schon aufgezeichnet wird. Die
  /// Entscheidung fasst die lebende Spur danach nicht mehr an.
  Future<void> _closeLoop() async {
    if (!_location.isLoopClosed()) return;

    final closedTrack = _location.getClosedTrack();
    if (closedTrack.isEmpty) return;

    // Beides vor continueAfterClaim() abgreifen — danach ist die Spur
    // zurückgesetzt und die Rundenwerte stehen auf null.
    final walkStats = _buildWalkStats();
    final closedAt = DateTime.now();

    _closingLoop = true;

    _pendingLoops = [
      ..._pendingLoops,
      PendingLoop(
        id: closedAt.microsecondsSinceEpoch.toString(),
        track: closedTrack,
        walkStats: walkStats,
        areaSqm: polygonAreaSqm(closedTrack),
        closedAt: closedAt,
        simulatedUserId: _simulatedUserId,
        simulatedUserName: _simulatedUserName,
      ),
    ];
    await _pendingLoopStore.save(_pendingLoops);

    // Steht man ohnehin auf der Karte, reicht der Dialog. Ein unbekannter
    // Lebenszyklus zaehlt als "nicht im Vordergrund" — eine Meldung zu viel
    // ist besser als eine verpasste Runde.
    final inForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!inForeground) {
      await _notifications.showLoopClosed(
        area: formatArea(_pendingLoops.last.areaSqm),
        openLoops: _pendingLoops.length,
      );
    }

    _location.continueAfterClaim();

    _closingLoop = false;
    notifyListeners();
  }

  /// Beansprucht eine abgelegte Runde. Schlägt das fehl, bleibt der Eintrag
  /// liegen — ein Funkloch oder ein abgelehnter Claim darf einen gelaufenen
  /// Lauf nicht wegwerfen, verworfen wird nur auf Ansage.
  Future<bool> confirmPendingLoop(String id) async {
    final index = _pendingLoops.indexWhere((l) => l.id == id);
    if (index < 0) return false;
    final loop = _pendingLoops[index];

    _isLoading = true;
    notifyListeners();

    try {
      // Der Spieler der Runde, nicht der gerade eingestellte — für den
      // nächsten Lauf ist längst umgestellt, bevor jemand hier antwortet.
      final result = loop.simulatedUserId != null
          ? await _api.devPlaceTerritory(
              loop.simulatedUserId!,
              loop.track,
              walkStats: loop.walkStats,
            )
          : await _api.claimTerritory(loop.track, walkStats: loop.walkStats);

      if (result.containsKey('error')) {
        _error = result['error'];
        return false;
      }

      if (result['territory'] != null) {
        _lastClaimedTerritory = Territory.fromJson(result['territory']);
      }
      _error = null;

      await _removePendingLoop(id);
      await loadTerritories();
      return true;
    } catch (e) {
      debugPrint('confirmPendingLoop: $e');
      _error = 'Failed to claim territory: $e';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> discardPendingLoop(String id) async {
    await _removePendingLoop(id);
    notifyListeners();
  }

  Future<void> _removePendingLoop(String id) async {
    _pendingLoops = _pendingLoops.where((l) => l.id != id).toList();
    await _pendingLoopStore.save(_pendingLoops);
    if (_pendingLoops.isEmpty) await _notifications.clearLoopClosed();
  }

  Future<List<dynamic>> getDevUsers() => _api.getDevUsers();

  void setSimulatedUser(String? userId, String? userName) {
    _simulatedUserId = userId;
    _simulatedUserName = userName;
    notifyListeners();
  }

  bool get isSimulating => _walkSimulator.isRunning;

  // --- Route zeichnen statt laufen -------------------------------------
  // Eine GPX-Datei je Testfall von Hand zu bauen war die eigentliche Hürde.
  // Angetippte Stützpunkte lassen jede Geometrie an jeder Stelle in Sekunden
  // entstehen: mitten im fremden Gebiet, vom Rand hereinbeissend, als Acht.

  bool _drawingRoute = false;
  final List<LatLng> _drawnRoute = [];

  /// Die zuletzt abgespielte Route, geschlossen. Bleibt liegen, damit
  /// derselbe Ring als anderer Spieler nochmal laufen kann — ohne das müsste
  /// man für jede Mehrspieler-Lage dieselbe Form ein zweites Mal treffen, und
  /// zwei von Hand getippte Ringe sind nie deckungsgleich.
  List<LatLng> _lastRoute = [];

  /// Abspieltempo als Vielfaches. Beim Fehlersuchen schnell, beim Zuschauen
  /// langsam.
  int _simulationSpeed = 1;

  bool get drawingRoute => _drawingRoute;
  bool get hasLastRoute => _lastRoute.length >= 4;
  List<LatLng> get drawnRoute => List.unmodifiable(_drawnRoute);
  int get simulationSpeed => _simulationSpeed;
  static const List<int> simulationSpeeds = [1, 5, 20];

  /// Länge der geschlossenen Route in Metern. Die Loop-Erkennung verlangt
  /// [LocationService.minTrackDistanceM] — ohne Anzeige tippt man eine zu
  /// kleine Runde und es passiert wortlos nichts.
  double get drawnRouteLengthM {
    if (_drawnRoute.length < 3) return 0;
    const distance = Distance();
    final ring = [..._drawnRoute, _drawnRoute.first];
    double total = 0;
    for (int i = 1; i < ring.length; i++) {
      total += distance.as(LengthUnit.Meter, ring[i - 1], ring[i]);
    }
    return total;
  }

  /// Fläche, die die gezeichnete Route umschliesst.
  double get drawnRouteAreaSqm =>
      _drawnRoute.length < 3 ? 0 : polygonAreaSqm(_drawnRoute);

  /// Ob die gezeichnete Route als Runde durchgeht.
  bool get drawnRouteIsWalkable =>
      drawnRouteLengthM >= LocationService.minTrackDistanceM &&
      drawnRouteAreaSqm >= LocationService.minAreaSqm;

  void setSimulationSpeed(int speed) {
    _simulationSpeed = speed;
    notifyListeners();
  }

  void startDrawingRoute() {
    _drawingRoute = true;
    _drawnRoute.clear();
    notifyListeners();
  }

  void addRoutePoint(LatLng point) {
    if (!_drawingRoute) return;
    _drawnRoute.add(point);
    notifyListeners();
  }

  void undoRoutePoint() {
    if (_drawnRoute.isEmpty) return;
    _drawnRoute.removeLast();
    notifyListeners();
  }

  void cancelDrawingRoute() {
    _drawingRoute = false;
    _drawnRoute.clear();
    notifyListeners();
  }

  /// Schliesst die gezeichnete Route und spielt sie als Lauf ab.
  ///
  /// Der erste Punkt wird angehängt, damit die Runde zu ist — sonst müsste man
  /// den Anfangspunkt pixelgenau ein zweites Mal treffen.
  Future<void> simulateDrawnRoute() async {
    if (_drawnRoute.length < 3) {
      _error = 'Mindestens 3 Punkte zeichnen.';
      notifyListeners();
      return;
    }
    if (!drawnRouteIsWalkable) {
      _error = 'Runde zu klein: ${drawnRouteLengthM.round()} m, '
          'gebraucht werden ${LocationService.minTrackDistanceM.round()} m.';
      notifyListeners();
      return;
    }

    _lastRoute = [..._drawnRoute, _drawnRoute.first];
    _drawingRoute = false;
    _drawnRoute.clear();
    notifyListeners();

    await _playRoute(_lastRoute);
  }

  /// Spielt die zuletzt gezeichnete Route erneut ab — als der Spieler, der
  /// gerade eingestellt ist. Genau derselbe Ring über fremdem Grund ergibt
  /// eine vollständige Übernahme samt Verlustmeldung beim Vorbesitzer.
  Future<void> replayLastRoute() async {
    if (!hasLastRoute) return;
    await _playRoute(_lastRoute);
  }

  Future<void> _playRoute(List<LatLng> route) async {
    _error = null;
    _lastClaimedTerritory = null;
    notifyListeners();

    try {
      await _walkSimulator.startSimulationFromPoints(
        route,
        intervalMs: 300 ~/ _simulationSpeed,
      );
    } catch (e) {
      _error = 'Walk simulation failed: $e';
      notifyListeners();
    }
  }

  /// Start simulating a walk from a GPX asset file.
  Future<void> simulateWalk(String assetPath) async {
    _error = null;
    _lastClaimedTerritory = null;
    notifyListeners();

    try {
      await _walkSimulator.startSimulation(
        assetPath,
        intervalMs: 300 ~/ _simulationSpeed,
      );
    } catch (e) {
      _error = 'Walk simulation failed: $e';
      notifyListeners();
    }
  }

  void stopSimulation() {
    _walkSimulator.stop();
    _location.stopTracking();
    notifyListeners();
  }

  /// Available GPX test walk files.
  static const List<String> testWalks = [
    'assets/test_walks/Lunch_Walk.gpx',
    'assets/test_walks/Mittagslauf.gpx',
    'assets/test_walks/groesser.gpx',
    'assets/test_walks/ueberschneiden.gpx',
  ];

  /// Fläche, die ein fremder Claim gerade gekostet hat. Wird von der Karte
  /// angezeigt und danach mit [clearLoss] quittiert.
  double? _lostAreaSqm;
  double? get lostAreaSqm => _lostAreaSqm;

  void clearLoss() {
    _lostAreaSqm = null;
  }

  void _handleWebSocketMessage(Map<String, dynamic> message) {
    if (message['type'] != 'territory_claimed') return;

    // Der eigene Claim ist keine Neuigkeit
    if (message['claimedBy'] != _userId) {
      final losses = (message['losses'] as List?) ?? const [];
      double lost = 0;
      for (final entry in losses) {
        final loss = entry as Map<String, dynamic>;
        if (loss['userId'] == _userId) {
          lost += (loss['lostAreaSqm'] as num?)?.toDouble() ?? 0;
        }
      }
      if (lost > 0) _lostAreaSqm = lost;
    }

    // Reload territories when someone claims new territory
    loadTerritories();
    loadStats();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _location.dispose();
    _ws.dispose();
    super.dispose();
  }
}
