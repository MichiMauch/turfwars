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

/// Flächengewichteter Schwerpunkt eines Rings.
///
/// Für die Beschriftung eines Gebiets. Bei stark eingebuchteten Formen (C oder
/// Hufeisen) kann er ausserhalb des Polygons liegen; für gelaufene Runden ist
/// das selten, und die saubere Lösung wäre für ein Namensschild zu viel
/// Aufwand. Entartet der Ring zu einer Linie, fällt es auf den Mittelwert der
/// Punkte zurück.
LatLng? polygonCentroid(List<LatLng> ring) {
  if (ring.isEmpty) return null;
  if (ring.length < 3) return ring.first;

  // Relativ zum ersten Punkt rechnen. Mit absoluten Koordinaten um 47/8 sind
  // die Kreuzprodukte riesig gegenüber den Differenzen, und die Stellen, auf
  // die es ankommt, fallen der Auslöschung zum Opfer.
  final originLat = ring.first.latitude;
  final originLng = ring.first.longitude;

  double twiceArea = 0;
  double x = 0;
  double y = 0;

  for (int i = 0; i < ring.length; i++) {
    final x1 = ring[i].longitude - originLng;
    final y1 = ring[i].latitude - originLat;
    final next = ring[(i + 1) % ring.length];
    final x2 = next.longitude - originLng;
    final y2 = next.latitude - originLat;

    final cross = x1 * y2 - x2 * y1;
    twiceArea += cross;
    x += (x1 + x2) * cross;
    y += (y1 + y2) * cross;
  }

  if (twiceArea.abs() < 1e-15) {
    // Alle Punkte auf einer Linie — die Formel teilte durch null.
    final lat = ring.map((p) => p.latitude).reduce((a, b) => a + b);
    final lng = ring.map((p) => p.longitude).reduce((a, b) => a + b);
    return LatLng(lat / ring.length, lng / ring.length);
  }

  return LatLng(
    originLat + y / (3 * twiceArea),
    originLng + x / (3 * twiceArea),
  );
}

/// Ein Kartenausschnitt in Grad.
///
/// Dient dazu, ein überflüssiges Nachladen zu erkennen: solange der sichtbare
/// Bereich im bereits geladenen liegt, gibt es nichts zu holen. Ohne das
/// stellt das Nachführen während eines Laufs bei jedem GPS-Punkt eine Anfrage.
class BoundsBox {
  const BoundsBox(this.minLng, this.minLat, this.maxLng, this.maxLat);

  final double minLng;
  final double minLat;
  final double maxLng;
  final double maxLat;

  /// Der Kasten, geweitet um [factor] seiner eigenen Kantenlänge je Seite.
  BoundsBox padded(double factor) {
    final padLng = (maxLng - minLng) * factor;
    final padLat = (maxLat - minLat) * factor;
    return BoundsBox(
      minLng - padLng,
      minLat - padLat,
      maxLng + padLng,
      maxLat + padLat,
    );
  }

  /// Ob [other] vollständig in diesem Kasten liegt. Ein Kasten enthält sich
  /// selbst.
  bool contains(BoundsBox other) =>
      other.minLng >= minLng &&
      other.minLat >= minLat &&
      other.maxLng <= maxLng &&
      other.maxLat <= maxLat;

  /// Als Wert für den bounds-Parameter von GET /territories.
  String get asQuery => [minLng, minLat, maxLng, maxLat].join(',');
}
