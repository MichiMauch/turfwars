import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';
import 'location_service.dart';

class WalkSimulator {
  final LocationService _location;
  Timer? _timer;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// Target number of points for simulation (~100 gives a good balance).
  static const int _targetPoints = 100;

  WalkSimulator(this._location);

  /// Load GPX file from assets and parse track points.
  static Future<List<LatLng>> loadGpx(String assetPath) async {
    final xml = await rootBundle.loadString(assetPath);
    return parseGpx(xml);
  }

  /// Parse GPX XML string into a list of LatLng points.
  static List<LatLng> parseGpx(String gpxXml) {
    final document = XmlDocument.parse(gpxXml);
    final points = <LatLng>[];

    // GPX uses <trkpt lat="..." lon="..."> inside <trkseg>
    final trkpts = document.findAllElements('trkpt');
    for (final trkpt in trkpts) {
      final lat = double.tryParse(trkpt.getAttribute('lat') ?? '');
      final lon = double.tryParse(trkpt.getAttribute('lon') ?? '');
      if (lat != null && lon != null) {
        points.add(LatLng(lat, lon));
      }
    }

    debugPrint('GPX parsed: ${points.length} track points');
    return points;
  }

  /// Downsample a list of points to approximately [targetCount] points,
  /// always keeping first and last point.
  static List<LatLng> downsample(List<LatLng> points, int targetCount) {
    if (points.length <= targetCount) return points;

    final result = <LatLng>[points.first];
    final step = (points.length - 1) / (targetCount - 1);

    for (int i = 1; i < targetCount - 1; i++) {
      result.add(points[(i * step).round()]);
    }
    result.add(points.last);

    return result;
  }

  /// Simulate a walk by injecting GPX points into the LocationService.
  /// Points are fed every [intervalMs] milliseconds.
  /// Large tracks are downsampled to ~[_targetPoints] points.
  Future<void> startSimulation(String assetPath,
      {int intervalMs = 300}) async {
    if (_isRunning) return;

    var points = await loadGpx(assetPath);
    if (points.isEmpty) {
      debugPrint('WalkSimulator: No points in GPX file');
      return;
    }

    // Downsample if too many points
    if (points.length > _targetPoints) {
      debugPrint('WalkSimulator: Downsampling ${points.length} → $_targetPoints points');
      points = downsample(points, _targetPoints);
    }

    final totalTimeSec = (points.length * intervalMs / 1000).toStringAsFixed(0);
    debugPrint(
        'WalkSimulator: Starting simulation with ${points.length} points, '
        'interval=${intervalMs}ms, total ~${totalTimeSec}s');

    _isRunning = true;

    // Start tracking in simulation mode (no GPS stream)
    _location.startSimulatedTracking();

    // Feed the first point immediately, then the rest via timer
    int index = 0;
    _location.injectPoint(points[index]);
    index++;

    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) {
      if (index >= points.length || !_isRunning) {
        debugPrint('WalkSimulator: Simulation complete '
            '(${points.length} points injected, track=${_location.track.length})');
        stop();
        return;
      }

      _location.injectPoint(points[index]);
      index++;
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _isRunning = false;
  }

  void dispose() {
    stop();
  }
}
