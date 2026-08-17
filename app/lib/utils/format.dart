/// Formatiert eine Fläche je nach Grössenordnung als m², ha oder km².
String formatArea(double sqm) {
  if (sqm >= 1000000) {
    return '${(sqm / 1000000).toStringAsFixed(2)} km²';
  } else if (sqm >= 10000) {
    return '${(sqm / 10000).toStringAsFixed(1)} ha';
  }
  return '${sqm.toStringAsFixed(0)} m²';
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
