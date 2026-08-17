/// Formatiert eine Fläche immer in km², mit so vielen Nachkommastellen,
/// dass auch kleine Gebiete noch einen Wert zeigen.
String formatArea(double sqm) {
  final km2 = sqm / 1000000;
  if (km2 <= 0) return '0 km²';
  if (km2 < 0.001) return '< 0.001 km²';
  if (km2 >= 100) return '${km2.toStringAsFixed(0)} km²';
  if (km2 >= 10) return '${km2.toStringAsFixed(1)} km²';
  return '${km2.toStringAsFixed(3)} km²';
}

/// Formatiert eine Distanz als m oder km.
String formatDistance(double meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
  return '${meters.toStringAsFixed(0)} m';
}

/// Prozentanteil, feiner aufgelöst wenn er sehr klein ist.
String formatPercent(double percent) {
  if (percent >= 10) return '${percent.toStringAsFixed(0)} %';
  if (percent >= 1) return '${percent.toStringAsFixed(1)} %';
  if (percent >= 0.01) return '${percent.toStringAsFixed(2)} %';
  return '< 0.01 %';
}

/// Deutscher Name einer Verwaltungsebene.
String levelLabel(String level) {
  switch (level) {
    case 'municipality':
      return 'Gemeinde';
    case 'district':
      return 'Bezirk';
    case 'canton':
      return 'Kanton';
    case 'country':
      return 'Land';
    default:
      return level;
  }
}
