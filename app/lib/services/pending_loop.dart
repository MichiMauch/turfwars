import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ein geschlossener Loop, der noch auf eine Entscheidung wartet.
///
/// Der Track ist bereits der fertige, geschlossene Ring — er wird beim
/// Schliessen aus dem LocationService herausgeschnappt und danach nicht mehr
/// angefasst, während die Aufzeichnung weiterläuft.
class PendingLoop {
  final String id;
  final List<LatLng> track;
  final Map<String, dynamic> walkStats;
  final double areaSqm;
  final DateTime closedAt;

  const PendingLoop({
    required this.id,
    required this.track,
    required this.walkStats,
    required this.areaSqm,
    required this.closedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'track': track.map((p) => [p.longitude, p.latitude]).toList(),
        'walkStats': walkStats,
        'areaSqm': areaSqm,
        'closedAt': closedAt.toIso8601String(),
      };

  static PendingLoop fromJson(Map<String, dynamic> json) => PendingLoop(
        id: json['id'] as String,
        track: (json['track'] as List)
            .map((p) => LatLng(
                  (p[1] as num).toDouble(),
                  (p[0] as num).toDouble(),
                ))
            .toList(),
        walkStats: Map<String, dynamic>.from(json['walkStats'] as Map),
        areaSqm: (json['areaSqm'] as num).toDouble(),
        closedAt: DateTime.parse(json['closedAt'] as String),
      );
}

/// Speicher für geschlossene, unbestätigte Loops.
///
/// Eine Liste und nicht ein einzelner Eintrag: nach einer geschlossenen Runde
/// läuft die Aufzeichnung weiter, damit eine direkt anschliessende zweite
/// Runde als eigener Loop erkannt wird. Bis jemand aufs Handy schaut, können
/// also mehrere Runden auf eine Antwort warten.
///
/// Persistiert, weil Android die App während einer Wanderung wegräumen kann —
/// genau dafür gibt es die Frist: ein Eintrag, der beim Laden älter als
/// [maxAge] ist, wird verworfen.
class PendingLoopStore {
  static const String _key = 'pending_loops';
  static const Duration maxAge = Duration(hours: 24);

  /// Lädt die noch gültigen Einträge. Abgelaufene werden dabei gleich
  /// weggeschrieben, damit sie nicht bei jedem Start neu aussortiert werden.
  Future<List<PendingLoop>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];

    List<PendingLoop> stored;
    try {
      stored = (jsonDecode(raw) as List)
          .map((e) => PendingLoop.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // Ein unlesbarer Eintrag darf die App nicht bei jedem Start aufhalten.
      debugPrint('PendingLoopStore: $e');
      await prefs.remove(_key);
      return [];
    }

    final cutoff = DateTime.now().subtract(maxAge);
    final valid = stored.where((l) => l.closedAt.isAfter(cutoff)).toList();
    if (valid.length != stored.length) {
      await _write(prefs, valid);
    }
    return valid;
  }

  Future<void> save(List<PendingLoop> loops) async {
    await _write(await SharedPreferences.getInstance(), loops);
  }

  Future<void> _write(SharedPreferences prefs, List<PendingLoop> loops) async {
    if (loops.isEmpty) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(
      _key,
      jsonEncode(loops.map((l) => l.toJson()).toList()),
    );
  }
}
