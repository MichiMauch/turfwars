import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../models/territory.dart';
import '../services/api_service.dart';
import '../services/location_service.dart';
import '../services/websocket_service.dart';

class GameProvider extends ChangeNotifier {
  final ApiService _api = ApiService();
  final LocationService _location = LocationService();
  final WebSocketService _ws = WebSocketService();

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
  bool get isTracking => _location.isTracking;
  LocationService get locationService => _location;

  GameProvider() {
    _location.trackStream.listen((track) {
      _currentTrack = track;
      notifyListeners();
    });

    _location.statusStream.listen((status) {
      _trackingStatus = status;
      notifyListeners();
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

    // Load territories
    await loadTerritories();

    // Load nearby regions
    if (_currentPosition != null) {
      await loadRegions();
    }
  }

  Future<void> loadTerritories() async {
    _isLoading = true;
    notifyListeners();

    try {
      final data = await _api.getTerritories();
      _territories = data.map((t) => Territory.fromJson(t)).toList();
      _error = null;
    } catch (e) {
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

  void startTracking() {
    _location.startTracking();
  }

  void stopTracking() {
    _location.stopTracking();
  }

  Future<bool> claimTerritory() async {
    if (!_location.isLoopClosed()) {
      _error = 'Loop is not closed (must be within 20m of start)';
      notifyListeners();
      return false;
    }

    final closedTrack = _location.getClosedTrack();
    if (closedTrack.isEmpty) return false;

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _api.claimTerritory(closedTrack);

      if (result.containsKey('error')) {
        _error = result['error'];
        _isLoading = false;
        notifyListeners();
        return false;
      }

      _location.clearTrack();
      _location.stopTracking();
      await loadTerritories();
      _error = null;
      return true;
    } catch (e) {
      _error = 'Failed to claim territory: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

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
