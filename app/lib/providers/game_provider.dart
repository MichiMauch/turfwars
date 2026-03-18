import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../models/territory.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
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
  List<AdminRegion> _regions = [];
  List<LatLng> _currentTrack = [];
  TrackingStatus _trackingStatus = TrackingStatus.stopped;
  bool _isLoading = false;
  String? _error;
  String? _userId;
  String? _displayName;
  LatLng? _currentPosition;
  String? _selectedRegionId;
  AdminRegion? _currentMunicipality;
  bool _municipalityConfirmed = false;
  bool _municipalityDetected = false;
  bool _autoClaimPending = false;
  Territory? _lastClaimedTerritory;

  // Getters
  List<Territory> get territories => _territories;
  List<RankingEntry> get rankings => _rankings;
  List<AdminRegion> get regions => _regions;
  List<LatLng> get currentTrack => _currentTrack;
  TrackingStatus get trackingStatus => _trackingStatus;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get userId => _userId;
  String? get displayName => _displayName;
  LatLng? get currentPosition => _currentPosition;
  String? get selectedRegionId => _selectedRegionId;
  AdminRegion? get currentMunicipality => _currentMunicipality;
  bool get municipalityConfirmed => _municipalityConfirmed;
  bool get municipalityDetected => _municipalityDetected;
  bool get autoClaimPending => _autoClaimPending;
  Territory? get lastClaimedTerritory => _lastClaimedTerritory;
  bool get isTracking => _location.isTracking;
  double get currentSpeedKmh => _location.currentSpeedMs * 3.6;
  double get totalDistanceM => _location.totalDistanceM;
  LocationService get locationService => _location;

  GameProvider() {
    _location.trackStream.listen((track) {
      _currentTrack = track;
      notifyListeners();
    });

    _location.statusStream.listen((status) {
      _trackingStatus = status;
      notifyListeners();

      // Auto-claim when loop is detected
      if (status == TrackingStatus.loopDetected && !_autoClaimPending) {
        _autoClaim();
      }
    });

    _ws.messages.listen(_handleWebSocketMessage);
  }

  void setAuthToken(String token) {
    _api.setAuthToken(token);
  }

  Future<void> login() async {
    try {
      final result = await _api.login();
      final user = result['user'];
      _userId = user['id'];
      _displayName = user['displayName'];
      notifyListeners();
    } catch (e) {
      _error = 'Login failed: $e';
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    final hasPermission = await _location.checkPermissions();
    if (!hasPermission) {
      _error = 'Location permission required';
      notifyListeners();
      return;
    }

    _currentPosition = await _location.getCurrentPosition();
    notifyListeners();

    // Connect WebSocket
    _ws.connect();

    // Load territories immediately
    await loadTerritories();

    // Locate municipality from GPS
    if (_currentPosition != null) {
      await _detectMunicipality();
    }
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

  Future<void> confirmMunicipality() async {
    if (_currentMunicipality == null) return;

    _municipalityConfirmed = true;
    _selectedRegionId = _currentMunicipality!.id;
    notifyListeners();

    // Load territories and regions now that user confirmed
    await loadTerritories();
    await loadRegions();
  }

  Future<void> loadTerritories() async {
    _isLoading = true;
    notifyListeners();

    try {
      final data = await _api.getTerritories();
      debugPrint('loadTerritories: got ${data.length} territories');
      for (final t in data) {
        debugPrint('Territory: ${t['id']} - polygon keys: ${t.keys.toList()}');
      }
      _territories = data.map((t) => Territory.fromJson(t)).toList();
      debugPrint('Parsed ${_territories.length} territories, first polygon points: ${_territories.isNotEmpty ? _territories.first.polygon.length : 0}');
      _error = null;
    } catch (e, stack) {
      debugPrint('loadTerritories error: $e\n$stack');
      _error = 'Failed to load territories: $e';
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
      _error = null;
    } catch (e) {
      _error = 'Failed to load rankings: $e';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadRegions() async {
    if (_currentPosition == null) return;

    try {
      final data = await _api.getNearbyRegions(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
      _regions = data.map((r) => AdminRegion.fromJson(r)).toList();
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load regions: $e';
      notifyListeners();
    }
  }

  Future<void> startTracking() async {
    _error = null;
    _lastClaimedTerritory = null;
    await _location.startTracking();
    notifyListeners();
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
    debugPrint('STOP: loopClosed=$loopClosed, autoClaimPending=$_autoClaimPending');
    if (loopClosed && !_autoClaimPending) {
      _autoClaim();
    }
    _location.stopTracking();
  }

  Map<String, dynamic> _buildWalkStats() {
    final trackCoords = _location.track
        .map((p) => [p.longitude, p.latitude])
        .toList();
    return {
      'distanceM': _location.totalDistanceM,
      'durationSec': _location.durationSec,
      'avgSpeedKmh': _location.avgSpeedKmh,
      'maxSpeedKmh': _location.maxSpeedKmh,
      'trackPointCount': _location.track.length,
      'trackCoordinates': trackCoords,
    };
  }

  Future<void> _autoClaim() async {
    if (!_location.isLoopClosed()) return;

    _autoClaimPending = true;
    notifyListeners();

    final closedTrack = _location.getClosedTrack();
    if (closedTrack.isEmpty) {
      _autoClaimPending = false;
      return;
    }

    final walkStats = _buildWalkStats();

    try {
      final result = await _api.claimTerritory(closedTrack, walkStats: walkStats);
      debugPrint('autoClaim result: $result');

      if (!result.containsKey('error')) {
        _location.clearTrack();
        _location.stopTracking();
        await loadTerritories();
        // Parse the claimed territory from the API response
        if (result['territory'] != null) {
          _lastClaimedTerritory = Territory.fromJson(result['territory']);
        }
        _error = null;
      } else {
        _error = result['error'];
        // Reset loop detection so user can continue walking a bigger loop
        _location.resetLoopDetection();
      }
    } catch (e) {
      debugPrint('autoClaim error: $e');
      _error = 'Auto-claim failed: $e';
    }

    _autoClaimPending = false;
    notifyListeners();
  }

  Future<bool> claimTerritory() async {
    if (!_location.isLoopClosed()) {
      _error = 'Loop is not closed (walk a loop or return to start)';
      notifyListeners();
      return false;
    }

    final closedTrack = _location.getClosedTrack();
    if (closedTrack.isEmpty) return false;

    final walkStats = _buildWalkStats();

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _api.claimTerritory(closedTrack, walkStats: walkStats);

      if (result.containsKey('error')) {
        _error = result['error'];
        _isLoading = false;
        notifyListeners();
        return false;
      }

      _location.clearTrack();
      _location.stopTracking();
      await loadTerritories();
      // Parse the claimed territory from the API response
      if (result['territory'] != null) {
        _lastClaimedTerritory = Territory.fromJson(result['territory']);
      }
      _error = null;
      return true;
    } catch (e) {
      _error = 'Failed to claim territory: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  bool get isSimulating => _walkSimulator.isRunning;

  /// Start simulating a walk from a GPX asset file.
  Future<void> simulateWalk(String assetPath) async {
    _error = null;
    _lastClaimedTerritory = null;
    notifyListeners();

    try {
      await _walkSimulator.startSimulation(assetPath);
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

  void _handleWebSocketMessage(Map<String, dynamic> message) {
    final type = message['type'];
    if (type == 'territory_claimed') {
      // Reload territories when someone claims new territory
      loadTerritories();
    }
  }

  @override
  void dispose() {
    _location.dispose();
    _ws.dispose();
    super.dispose();
  }
}
