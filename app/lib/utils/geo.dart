import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Derselbe Radius, mit dem @turf/helpers rechnet (earthRadius = 6371008.8),
/// nicht die WGS84-Halbachse 6378137. Der Unterschied sind 0.22 Prozent Fläche
/// — genug, dass die Anzeige beim Zeichnen von der Serverantwort abweicht.
const double _earthRadiusM = 6371008.8;

double _rad(double deg) => deg * math.pi / 180;

/// Fläche eines geschlossenen Rings in Quadratmetern.
///
/// Dieselbe Formel wie @turf/area auf dem Server, damit die Zahl im
/// Bestätigungsdialog nicht von der abweicht, die nach dem Beanspruchen
/// zurückkommt. Der Ring darf offen oder geschlossen übergeben werden.
double polygonAreaSqm(List<LatLng> ring) {
  if (ring.length < 3) return 0;

  double total = 0;
  for (int i = 0; i < ring.length; i++) {
    final p1 = ring[i];
    final p2 = ring[(i + 1) % ring.length];
    total += _rad(p2.longitude - p1.longitude) *
        (2 + math.sin(_rad(p1.latitude)) + math.sin(_rad(p2.latitude)));
  }

  return (total * _earthRadiusM * _earthRadiusM / 2).abs();
}
