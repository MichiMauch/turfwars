import 'package:flutter/material.dart';

/// Gold, Silber, Bronze für die ersten drei Plätze.
///
/// Wie die Spielerfarben sind das Daten und kein Erscheinungsbild: Gold bleibt
/// Gold, auch wenn die App eines Tages blau wird. Deshalb stehen sie hier und
/// nicht im ColorScheme — dort wären sie eine Farbe unter vielen und würden
/// beim nächsten Themenwechsel mitwandern.
Color medalColor(int rank) => switch (rank) {
      1 => const Color(0xFFFFC107), // Gold
      2 => const Color(0xFFBDBDBD), // Silber
      3 => const Color(0xFFA1887F), // Bronze
      _ => const Color(0xFFEEEEEE), // kein Podest
    };

/// Ob dieser Platz ein Podestplatz ist und damit eine Medaille trägt.
bool isPodium(int rank) => rank >= 1 && rank <= 3;
