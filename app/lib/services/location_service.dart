import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Result of a self-intersection check.
class IntersectionResult {
  /// Index of the first point of the earlier segment that was crossed.
  final int segmentIndex;

  /// The exact point where the two segments cross.
  final LatLng intersectionPoint;

  IntersectionResult(this.segmentIndex, this.intersectionPoint);
}

class LocationService {
  StreamSubscription<Position>? _positionSubscription;
  final List<LatLng> _track = [];
  bool _isTracking = false;
  double _currentSpeedMs = 0.0;
  // Zwei Ebenen, seit die Aufzeichnung nach einer geschlossenen Runde
  // weiterläuft: die Runde ist das, was am Ende ans Gebiet geschrieben wird
  // und woran die Loop-Erkennung ihre Mindestwerte misst. Der Lauf ist das,
  // was die Anzeige zeigt — der darf beim Rundenwechsel nicht auf 0 springen.
  double _maxSpeedMs = 0.0;
  double _totalDistanceM = 0.0;
  double _maxDistanceFromStartM = 0.0;
  DateTime? _trackingStartTime;
  double _walkMaxSpeedMs = 0.0;
  double _walkDistanceM = 0.0;
  DateTime? _walkStartTime;
  final _trackController = StreamController<List<LatLng>>.broadcast();
  final _statusController = StreamController<TrackingStatus>.broadcast();

  /// When a self-intersection is detected, stores the loop slice info.
  IntersectionResult? _loopIntersection;

  /// When true, GPS stream is not started (points come via injectPoint only).
  bool _simulationMode = false;

  List<LatLng> get track => List.unmodifiable(_track);
  bool get isTracking => _isTracking;
  double get currentSpeedMs => _currentSpeedMs;
  double get maxSpeedMs => _maxSpeedMs;

  /// Gehtempo, mit dem eine Simulation rechnet — die Punkte kommen im
  /// Zeitraffer, echte Sekunden wären als Dauer sinnlos und der Server
  /// würde den Claim zu Recht als zu schnell abweisen.
  static const double simulatedSpeedMs = 1.4;

  // Werte der laufenden Runde. Sie gehen mit dem Claim ans Gebiet und werden
  // von continueAfterClaim() zurückgesetzt.
  double get loopDistanceM => _totalDistanceM;

  int get loopDurationSec {
    if (_simulationMode) return (_totalDistanceM / simulatedSpeedMs).round();
    return _trackingStartTime != null
        ? DateTime.now().difference(_trackingStartTime!).inSeconds
        : 0;
  }

  double get loopAvgSpeedKmh =>
      loopDurationSec > 0 ? (_totalDistanceM / loopDurationSec) * 3.6 : 0.0;
  double get loopMaxSpeedKmh => _maxSpeedMs * 3.6;

  // Werte des ganzen Laufs seit dem Start der Aufzeichnung. Das ist, was die
  // Anzeige zeigt; eine geschlossene Runde lässt sie unberührt.
  double get walkDistanceM => _walkDistanceM;

  int get walkDurationSec {
    if (_simulationMode) return (_walkDistanceM / simulatedSpeedMs).round();
    return _walkStartTime != null
        ? DateTime.now().difference(_walkStartTime!).inSeconds
        : 0;
  }

  double get walkAvgSpeedKmh =>
      walkDurationSec > 0 ? (_walkDistanceM / walkDurationSec) * 3.6 : 0.0;
  double get walkMaxSpeedKmh => _walkMaxSpeedMs * 3.6;
  Stream<List<LatLng>> get trackStream => _trackController.stream;
  Stream<TrackingStatus> get statusStream => _statusController.stream;

  static const double loopCloseDistanceM = 30.0;
  static const double minAreaSqm = 100.0;
  static const double minTrackDistanceM = 100.0;
  static const double minDistanceFromStartM = 30.0;

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

  /// So lange darf ein genauer Fix höchstens dauern. Ohne Grenze hängt der
  /// Aufruf drinnen beliebig lange — er hielt damit den ganzen App-Start auf.
  static const Duration positionTimeout = Duration(seconds: 8);

  /// Die zuletzt bekannte Position, sofort und ohne Funkverkehr.
  ///
  /// Beim Start ist eine ungefähre Position, die es jetzt gibt, mehr wert als
  /// eine genaue in zwei Sekunden: die Karte steht sonst in Zürich.
  Future<LatLng?> getLastKnownPosition() async {
    try {
      final position = await Geolocator.getLastKnownPosition();
      if (position == null) return null;
      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      return null;
    }
  }

  Future<LatLng?> getCurrentPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(positionTimeout);
      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      // Auch der Timeout landet hier. Kein Fix ist kein Fehler, der jemanden
      // aufhalten darf — die Karte kommt dann eben ohne aus.
      debugPrint('getCurrentPosition: $e');
      return null;
    }
  }

  /// Start tracking in simulation mode (no GPS stream, points via injectPoint).
  void startSimulatedTracking() {
    if (_isTracking) return;
    _simulationMode = true;
    _isTracking = true;
    _track.clear();
    _loopIntersection = null;
    _currentSpeedMs = 0.0;
    _maxSpeedMs = 0.0;
    _totalDistanceM = 0.0;
    _maxDistanceFromStartM = 0.0;
    _trackingStartTime = DateTime.now();
    _walkMaxSpeedMs = 0.0;
    _walkDistanceM = 0.0;
    _walkStartTime = DateTime.now();
    _statusController.add(TrackingStatus.tracking);
  }

  Future<void> startTracking() async {
    if (_isTracking) return;
    _simulationMode = false;
    _isTracking = true;
    _track.clear();
    _loopIntersection = null;
    _currentSpeedMs = 0.0;
    _maxSpeedMs = 0.0;
    _totalDistanceM = 0.0;
    _maxDistanceFromStartM = 0.0;
    _trackingStartTime = DateTime.now();
    _walkMaxSpeedMs = 0.0;
    _walkDistanceM = 0.0;
    _walkStartTime = DateTime.now();

    _statusController.add(TrackingStatus.tracking);

    // Platform-specific location settings for background tracking. On Android
    // the foregroundNotificationConfig below starts geolocator's own
    // foreground service — that is what keeps fixes coming while the app is
    // in the background or the screen is off.
    LocationSettings locationSettings;
    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Turf Wars',
          notificationText: 'Walk wird aufgezeichnet...',
          enableWakeLock: true,
        ),
      );
    } else if (Platform.isIOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        activityType: ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      );
    }

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((position) {
      _currentSpeedMs = position.speed >= 0 ? position.speed : 0.0;
      if (_currentSpeedMs > _maxSpeedMs) {
        _maxSpeedMs = _currentSpeedMs;
      }
      if (_currentSpeedMs > _walkMaxSpeedMs) {
        _walkMaxSpeedMs = _currentSpeedMs;
      }
      _processNewPoint(LatLng(position.latitude, position.longitude));
    });
  }

  /// Inject a point as if it came from GPS. Used by WalkSimulator.
  void injectPoint(LatLng point) {
    _processNewPoint(point);
  }

  void _processNewPoint(LatLng point) {
    if (_track.isNotEmpty) {
      final step = const Distance().as(LengthUnit.Meter, _track.last, point);
      _totalDistanceM += step;
      _walkDistanceM += step;
    }

    _track.add(point);
    _trackController.add(List.unmodifiable(_track));

    // Track max distance from start for loop detection
    if (_track.length >= 2) {
      final distFromStart = const Distance().as(
        LengthUnit.Meter,
        _track.first,
        point,
      );
      if (distFromStart > _maxDistanceFromStartM) {
        _maxDistanceFromStartM = distFromStart;
      }
    }

    // Check for loop: self-intersection or start==end
    if (_track.length >= 4) {
      // 1. Check self-intersection (new segment crosses an earlier one)
      if (_loopIntersection == null) {
        final intersection = _findSelfIntersection();
        if (intersection != null) {
          _loopIntersection = intersection;
          final loopPoints = _track.length - intersection.segmentIndex;
          debugPrint('SELF-INTERSECTION at segment ${intersection.segmentIndex}, '
              'loop has $loopPoints points, '
              'intersection=${intersection.intersectionPoint}');
          if (_isLoopValid()) {
            debugPrint('LOOP DETECTED (self-intersection)!');
            _statusController.add(TrackingStatus.loopDetected);
          }
        }
      }

      // 2. Fallback: start==end check
      if (_loopIntersection == null) {
        final distance = const Distance().as(
          LengthUnit.Meter,
          _track.first,
          _track.last,
        );
        debugPrint('LOOP CHECK: points=${_track.length}, '
            'totalDist=${_totalDistanceM.toStringAsFixed(0)}m (need >=$minTrackDistanceM), '
            'maxFromStart=${_maxDistanceFromStartM.toStringAsFixed(0)}m (need >=$minDistanceFromStartM), '
            'distToStart=${distance.toStringAsFixed(1)}m (need <=$loopCloseDistanceM)');
        if (_totalDistanceM >= minTrackDistanceM &&
            _maxDistanceFromStartM >= minDistanceFromStartM &&
            distance <= loopCloseDistanceM) {
          debugPrint('LOOP DETECTED (start==end)!');
          _statusController.add(TrackingStatus.loopDetected);
        }
      }
    }
  }

  /// Manually add a point to the track (e.g. fresh GPS fix before stopping).
  void addPoint(LatLng point) {
    if (_track.isEmpty) return;

    final step = const Distance().as(LengthUnit.Meter, _track.last, point);
    _totalDistanceM += step;
    _walkDistanceM += step;

    final distFromStart = const Distance().as(
      LengthUnit.Meter,
      _track.first,
      point,
    );
    if (distFromStart > _maxDistanceFromStartM) {
      _maxDistanceFromStartM = distFromStart;
    }

    _track.add(point);
    _trackController.add(List.unmodifiable(_track));
  }

  void stopTracking() {
    _isTracking = false;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _simulationMode = false;
    _statusController.add(TrackingStatus.stopped);
  }

  bool isLoopClosed() {
    // Case 1: Self-intersection detected
    if (_loopIntersection != null && _isLoopValid()) {
      debugPrint('isLoopClosed: true (self-intersection at segment ${_loopIntersection!.segmentIndex})');
      return true;
    }

    // Case 2: Start==End
    if (_track.length < 4) {
      debugPrint('isLoopClosed: false (only ${_track.length} points)');
      return false;
    }
    if (_totalDistanceM < minTrackDistanceM) {
      debugPrint('isLoopClosed: false (totalDist=${_totalDistanceM.toStringAsFixed(0)}m < $minTrackDistanceM)');
      return false;
    }
    if (_maxDistanceFromStartM < minDistanceFromStartM) {
      debugPrint('isLoopClosed: false (maxFromStart=${_maxDistanceFromStartM.toStringAsFixed(0)}m < $minDistanceFromStartM)');
      return false;
    }
    final distance = const Distance().as(
      LengthUnit.Meter,
      _track.first,
      _track.last,
    );
    debugPrint('isLoopClosed: distToStart=${distance.toStringAsFixed(1)}m (need <=$loopCloseDistanceM) → ${distance <= loopCloseDistanceM}');
    return distance <= loopCloseDistanceM;
  }

  List<LatLng> getClosedTrack() {
    if (!isLoopClosed()) return [];

    // Case 1: Self-intersection → return only the loop slice
    if (_loopIntersection != null && _isLoopValid()) {
      final ix = _loopIntersection!;
      // Loop = intersection point, track[segmentIndex+1] ... track[last], intersection point
      final loopSlice = <LatLng>[
        ix.intersectionPoint,
        ..._track.sublist(ix.segmentIndex + 1),
        ix.intersectionPoint,
      ];
      debugPrint('getClosedTrack: self-intersection loop with ${loopSlice.length} points');
      return loopSlice;
    }

    // Case 2: Start==End → return full track closed
    return [..._track, _track.first];
  }

  /// Check if the detected loop meets minimum requirements.
  bool _isLoopValid() {
    if (_loopIntersection == null) return false;
    final loopPointCount = _track.length - _loopIntersection!.segmentIndex;
    if (loopPointCount < 4) return false;

    // Calculate distance of the loop portion
    double loopDist = 0;
    final startIdx = _loopIntersection!.segmentIndex;
    for (int i = startIdx; i < _track.length - 1; i++) {
      loopDist += const Distance().as(LengthUnit.Meter, _track[i], _track[i + 1]);
    }
    if (loopDist < minTrackDistanceM) return false;

    return true;
  }

  /// Check if the newest segment (track[n-1] → track[n]) crosses any earlier segment.
  IntersectionResult? _findSelfIntersection() {
    if (_track.length < 4) return null;
    final n = _track.length - 1;
    final p3 = _track[n - 1];
    final p4 = _track[n];

    // Check against all segments except the immediately previous one (n-2 → n-1)
    for (int i = 0; i <= n - 3; i++) {
      final hit = segmentIntersection(_track[i], _track[i + 1], p3, p4);
      if (hit != null) {
        return IntersectionResult(i, hit);
      }
    }
    return null;
  }

  /// Compute the intersection point of segments (p1,p2) and (p3,p4), or null.
  /// Uses 2D parametric line intersection with cross products.
  static LatLng? segmentIntersection(
      LatLng p1, LatLng p2, LatLng p3, LatLng p4) {
    final dx1 = p2.latitude - p1.latitude;
    final dy1 = p2.longitude - p1.longitude;
    final dx2 = p4.latitude - p3.latitude;
    final dy2 = p4.longitude - p3.longitude;

    final denom = dx1 * dy2 - dy1 * dx2;
    if (denom.abs() < 1e-12) return null; // Parallel or collinear

    final dx3 = p3.latitude - p1.latitude;
    final dy3 = p3.longitude - p1.longitude;

    final t = (dx3 * dy2 - dy3 * dx2) / denom;
    final u = (dx3 * dy1 - dy3 * dx1) / denom;

    // Both parameters must be in (0,1) — exclusive to avoid touching at endpoints
    if (t <= 0 || t >= 1 || u <= 0 || u >= 1) return null;

    return LatLng(
      p1.latitude + t * dx1,
      p1.longitude + t * dy1,
    );
  }

  /// Reset loop detection state so a new loop can be detected while still tracking.
  void resetLoopDetection() {
    _loopIntersection = null;
  }

  /// After a closed loop, trim the track so only the last point remains as the
  /// start of a potential new loop. Resets the loop's own stats and the loop
  /// detection but keeps tracking active — and deliberately leaves the walk
  /// totals alone, so the display does not jump back to zero mid-walk.
  void continueAfterClaim() {
    final lastPoint = _track.isNotEmpty ? _track.last : null;
    _track.clear();
    _loopIntersection = null;
    _totalDistanceM = 0;
    _maxDistanceFromStartM = 0;
    _trackingStartTime = DateTime.now();
    if (lastPoint != null) {
      _track.add(lastPoint);
    }
    _trackController.add(List.unmodifiable(_track));
    _statusController.add(TrackingStatus.tracking);
  }

  /// Skip past the current intersection so the same crossing isn't re-detected.
  /// Trims the loop portion from the track, keeping only the pre-loop part
  /// plus the current position.
  void skipPastIntersection() {
    if (_loopIntersection == null) return;
    final segIdx = _loopIntersection!.segmentIndex;
    final lastPoint = _track.isNotEmpty ? _track.last : null;

    // Keep track[0..segIdx] + intersection point as new track
    final kept = <LatLng>[
      ..._track.sublist(0, segIdx + 1),
      _loopIntersection!.intersectionPoint,
    ];
    if (lastPoint != null) {
      kept.add(lastPoint);
    }

    // Recalculate distance for kept portion
    double dist = 0;
    double maxFromStart = 0;
    for (int i = 1; i < kept.length; i++) {
      dist += const Distance().as(LengthUnit.Meter, kept[i - 1], kept[i]);
      final d = const Distance().as(LengthUnit.Meter, kept.first, kept[i]);
      if (d > maxFromStart) maxFromStart = d;
    }

    _track.clear();
    _track.addAll(kept);
    _loopIntersection = null;
    _totalDistanceM = dist;
    _maxDistanceFromStartM = maxFromStart;
    _trackController.add(List.unmodifiable(_track));
    _statusController.add(TrackingStatus.tracking);
  }

  void clearTrack() {
    _track.clear();
    _loopIntersection = null;
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
