import 'dart:convert';
import 'package:latlong2/latlong.dart';

class Territory {
  final String id;
  final String userId;
  final String displayName;
  final String? avatarUrl;

  /// Äusserer Ring des Gebiets.
  final List<LatLng> polygon;

  /// Innere Ringe — Stücke, die jemand herausgebissen hat. Ohne sie würde
  /// die Karte ein Gebiet als geschlossen zeigen, das ein Loch hat.
  final List<List<LatLng>> holes;

  final double areaSqm;
  final DateTime createdAt;

  Territory({
    required this.id,
    required this.userId,
    required this.displayName,
    this.avatarUrl,
    required this.polygon,
    this.holes = const [],
    required this.areaSqm,
    required this.createdAt,
  });

  factory Territory.fromJson(Map<String, dynamic> json) {
    final geojson = json['polygonGeojson'];
    final rings =
        geojson is String ? _parseGeojson(geojson) : _parseGeojsonMap(geojson);

    return Territory(
      id: json['id'],
      userId: json['userId'],
      displayName: json['displayName'] ?? 'Unknown',
      avatarUrl: json['avatarUrl'],
      polygon: rings.isEmpty ? const [] : rings.first,
      holes: rings.length > 1 ? rings.sublist(1) : const [],
      areaSqm: (json['areaSqm'] as num).toDouble(),
      createdAt: json['createdAt'] != null
          ? (json['createdAt'] is int
              ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] * 1000)
              : DateTime.parse(json['createdAt']))
          : DateTime.now(),
    );
  }

  static List<List<LatLng>> _parseGeojson(String geojsonStr) {
    final geojson = jsonDecode(geojsonStr) as Map<String, dynamic>;
    return _parseGeojsonMap(geojson);
  }

  static List<List<LatLng>> _parseGeojsonMap(dynamic geojson) {
    final map = geojson as Map<String, dynamic>;
    final geometry = map['geometry'] ?? map;
    final rings = geometry['coordinates'] as List;

    return rings
        .map<List<LatLng>>((ring) => (ring as List)
            .map((c) =>
                LatLng((c as List)[1].toDouble(), (c[0] as num).toDouble()))
            .toList())
        .toList();
  }
}

class RankingEntry {
  final int? rank;
  final String userId;
  final String displayName;
  final String? avatarUrl;
  final double totalAreaSqm;
  final int territoryCount;

  RankingEntry({
    this.rank,
    required this.userId,
    required this.displayName,
    this.avatarUrl,
    required this.totalAreaSqm,
    this.territoryCount = 0,
  });

  factory RankingEntry.fromJson(Map<String, dynamic> json) {
    return RankingEntry(
      rank: json['rank'],
      userId: json['userId'],
      displayName: json['displayName'] ?? 'Unknown',
      avatarUrl: json['avatarUrl'],
      totalAreaSqm: (json['totalAreaSqm'] as num).toDouble(),
      territoryCount: json['territoryCount'] ?? 0,
    );
  }
}

/// Wie viel ein Spieler in einer Region besitzt.
class RegionHolding {
  final String id;
  final String name;
  final String level;
  final double areaSqm;

  /// Fläche der Region selbst, null wenn keine Grenze hinterlegt ist
  final double? regionAreaSqm;

  /// Anteil an der Region in Prozent, null ohne Grenze
  final double? sharePercent;

  final int? rank;

  RegionHolding({
    required this.id,
    required this.name,
    required this.level,
    required this.areaSqm,
    this.regionAreaSqm,
    this.sharePercent,
    this.rank,
  });

  factory RegionHolding.fromJson(Map<String, dynamic> json) {
    return RegionHolding(
      id: json['id'],
      name: json['name'] ?? json['id'],
      level: json['level'],
      areaSqm: (json['areaSqm'] as num).toDouble(),
      regionAreaSqm: (json['regionAreaSqm'] as num?)?.toDouble(),
      sharePercent: (json['sharePercent'] as num?)?.toDouble(),
      rank: json['rank'],
    );
  }
}

/// Gesamtübersicht über den eigenen Besitz.
class PlayerStats {
  final int territoryCount;
  final double totalAreaSqm;
  final double largestAreaSqm;
  final double totalDistanceM;
  final List<RegionHolding> regions;

  PlayerStats({
    required this.territoryCount,
    required this.totalAreaSqm,
    required this.largestAreaSqm,
    required this.totalDistanceM,
    required this.regions,
  });

  factory PlayerStats.fromJson(Map<String, dynamic> json) {
    return PlayerStats(
      territoryCount: json['territoryCount'] ?? 0,
      totalAreaSqm: (json['totalAreaSqm'] as num?)?.toDouble() ?? 0,
      largestAreaSqm: (json['largestAreaSqm'] as num?)?.toDouble() ?? 0,
      totalDistanceM: (json['totalDistanceM'] as num?)?.toDouble() ?? 0,
      regions: ((json['regions'] as List?) ?? [])
          .map((r) => RegionHolding.fromJson(r as Map<String, dynamic>))
          .toList(),
    );
  }

  List<RegionHolding> onLevel(String level) =>
      regions.where((r) => r.level == level).toList();
}

class AdminRegion {
  final String id;
  final String name;
  final String level;
  final String? parentId;

  AdminRegion({
    required this.id,
    required this.name,
    required this.level,
    this.parentId,
  });

  factory AdminRegion.fromJson(Map<String, dynamic> json) {
    return AdminRegion(
      id: json['id'],
      name: json['name'],
      level: json['level'],
      parentId: json['parentId'],
    );
  }
}
