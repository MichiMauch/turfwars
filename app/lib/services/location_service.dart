import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class LocationService {
  StreamSubscription<Position>? _positionSubscription;
  final List<LatLng> _track = [];
  bool _isTracking = false;
  double _currentSpeedMs = 0.0;
  double _maxSpeedMs = 0.0;
  double _totalDistanceM = 0.0;
  DateTime? _trackingStartTime;
  final _trackController = StreamController<List<LatLng>>.broadcast();
  final _statusController = StreamController<TrackingStatus>.broadcast();

  List<LatLng> get track => List.unmodifiable(_track);
  bool get isTracking => _isTracking;
  double get currentSpeedMs => _currentSpeedMs;
  double get maxSpeedMs => _maxSpeedMs;
  double get totalDistanceM => _totalDistanceM;
  int get durationSec => _trackingStartTime != null
      ? DateTime.now().difference(_trackingStartTime!).inSeconds
      : 0;
  double get avgSpeedKmh => durationSec > 0
      ? (totalDistanceM / durationSec) * 3.6
      : 0.0;
  double get maxSpeedKmh => _maxSpeedMs * 3.6;
  Stream<List<LatLng>> get trackStream => _trackController.stream;
  Stream<TrackingStatus> get statusStream => _statusController.stream;

  static const double loopCloseDistanceM = 20.0;
  static const double minAreaSqm = 100.0;

  Future<bool> checkPermissions() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) return false;

    return true;
  }

  Future<LatLng?> getCurrentPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      return null;
    }
  }

  void startTracking() {
    if (_isTracking) return;
    _isTracking = true;
    _track.clear();
    _currentSpeedMs = 0.0;
    _maxSpeedMs = 0.0;
    _totalDistanceM = 0.0;
    _trackingStartTime = DateTime.now();

    _statusController.add(TrackingStatus.tracking);

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // Update every 5 meters
      ),
    ).listen((position) {
      final point = LatLng(position.latitude, position.longitude);

      _currentSpeedMs = position.speed >= 0 ? position.speed : 0.0;
      if (_currentSpeedMs > _maxSpeedMs) {
        _maxSpeedMs = _currentSpeedMs;
      }

      if (_track.isNotEmpty) {
        _totalDistanceM += const Distance().as(
          LengthUnit.Meter,
          _track.last,
          point,
        );
      }

      _track.add(point);
      _trackController.add(List.unmodifiable(_track));

      // Check if loop is closing
      if (_track.length >= 4) {
        final distance = const Distance().as(
          LengthUnit.Meter,
          _track.first,
          _track.last,
        );
        if (distance <= loopCloseDistanceM) {
          _statusController.add(TrackingStatus.loopDetected);
        }
      }
    });
  }

  void stopTracking() {
    _isTracking = false;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _statusController.add(TrackingStatus.stopped);
  }

  bool isLoopClosed() {
    if (_track.length < 4) return false;
    final distance = const Distance().as(
      LengthUnit.Meter,
      _track.first,
      _track.last,
    );
    return distance <= loopCloseDistanceM;
  }

  List<LatLng> getClosedTrack() {
    if (!isLoopClosed()) return [];
    return [..._track, _track.first]; // Close the polygon
  }

  void clearTrack() {
    _track.clear();
    _trackController.add([]);
  }

  void dispose() {
    _positionSubscription?.cancel();
    _trackController.close();
    _statusController.close();
  }
}

enum TrackingStatus {
  stopped,
  tracking,
  loopDetected,
}
