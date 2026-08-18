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

  /// Target number of points for simulation. Higher = more accurate
  /// intersection detection, but longer simulation time.
  static const int _targetPoints = 300;

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

  /// Abstand, auf den eine gezeichnete Route verdichtet wird. Derselbe Wert
  /// wie der distanceFilter der echten Aufzeichnung, damit eine gezeichnete
  /// Runde dieselbe Punktdichte hat wie eine gelaufene.
  static const double _densifyStepM = 5.0;

  /// Legt zwischen den Stützpunkten Zwischenpunkte, bis nirgends mehr als
  /// [_densifyStepM] Abstand ist.
  ///
  /// Eine mit vier Ecken getippte Route hat sonst vier Punkte — zu wenig für
  /// die Selbstüberschneidung und unter MIN_TRACK_POINTS des Servers.
  static List<LatLng> densify(List<LatLng> points) {
    if (points.length < 2) return points;

    const distance = Distance();
    final result = <LatLng>[points.first];

    for (int i = 1; i < points.length; i++) {
      final from = points[i - 1];
      final to = points[i];
      final meters = distance.as(LengthUnit.Meter, from, to);
      final steps = (meters / _densifyStepM).ceil();

      for (int step = 1; step <= steps; step++) {
        final t = step / steps;
        result.add(LatLng(
          from.latitude + (to.latitude - from.latitude) * t,
          from.longitude + (to.longitude - from.longitude) * t,
        ));
      }
    }

    return result;
  }

  /// Spielt eine auf der Karte gezeichnete Route als Lauf ab.
  ///
  /// [points] sind die getippten Stützpunkte in Reihenfolge; sie werden
  /// verdichtet und dann wie GPX-Punkte eingespeist.
  Future<void> startSimulationFromPoints(
    List<LatLng> points, {
    int intervalMs = 300,
  }) async {
    if (_isRunning) return;
    if (points.length < 2) {
      debugPrint('WalkSimulator: need at least 2 points to draw a walk');
      return;
    }
    _run(densify(points), intervalMs);
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

    _run(points, intervalMs);
  }

  void _run(List<LatLng> points, int intervalMs) {
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
