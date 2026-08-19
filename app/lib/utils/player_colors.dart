import 'package:flutter/material.dart';

/// Die Farben, die ein Spieler tragen kann.
///
/// Muss zu PLAYER_COLORS in backend/src/services/colors.ts passen. Der Server
/// entscheidet, was gültig ist — driftet diese Liste, lehnt er eine unbekannte
/// Farbe ab. Unschön, aber nicht still falsch.
const List<String> playerColors = [
  '#E53935',
  '#D81B60',
  '#8E24AA',
  '#5E35B1',
  '#3949AB',
  '#1E88E5',
  '#00ACC1',
  '#00897B',
  '#43A047',
  '#F9A825',
  '#FB8C00',
  '#6D4C41',
];

/// Fällt zurück, wenn ein Gebiet noch keine Farbe trägt — etwa solange der
/// Backfill nicht durch ist. Grau statt einer Palettenfarbe, damit ein
/// fehlender Wert nicht wie die bewusste Wahl eines Spielers aussieht.
const Color unknownPlayerColor = Color(0xFF9E9E9E);

/// Wandelt "#RRGGBB" in eine Farbe. Unlesbares ergibt [unknownPlayerColor] —
/// eine kaputte Farbe darf die Karte nicht mitreissen.
Color playerColorFrom(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) {
    return unknownPlayerColor;
  }
  final value = int.tryParse(hex.substring(1), radix: 16);
  if (value == null) return unknownPlayerColor;
  return Color(0xFF000000 | value);
}
