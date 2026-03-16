import 'dart:convert';
import 'package:latlong2/latlong.dart';

class Territory {
  final String id;
  final String userId;
  final String displayName;
  final String? avatarUrl;
  final List<LatLng> polygon;
  final double areaSqm;
  final DateTime createdAt;

  Territory({
    required this.id,
    required this.userId,
    required this.displayName,
    this.avatarUrl,
    required this.polygon,
    required this.areaSqm,
    required this.createdAt,
  });

  factory Territory.fromJson(Map<String, dynamic> json) {
    final geojson = json['polygonGeojson'];
    final parsed =
        geojson is String ? _parseGeojson(geojson) : _parseGeojsonMap(geojson);

    return Territory(
      id: json['id'],
      userId: json['userId'],
      displayName: json['displayName'] ?? 'Unknown',
      avatarUrl: json['avatarUrl'],
      polygon: parsed,
      areaSqm: (json['areaSqm'] as num).toDouble(),
      createdAt: json['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] * 1000)
          : DateTime.now(),
    );
  }

  static List<LatLng> _parseGeojson(String geojsonStr) {
    final geojson = jsonDecode(geojsonStr) as Map<String, dynamic>;
    return _parseGeojsonMap(geojson);
  }

  static List<LatLng> _parseGeojsonMap(dynamic geojson) {
    final map = geojson as Map<String, dynamic>;
    final geometry = map['geometry'] ?? map;
    final coords = (geometry['coordinates'] as List)[0] as List;
    return coords
        .map((c) => LatLng((c as List)[1].toDouble(), (c[0] as num).toDouble()))
        .toList();
  }
}

class RankingEntry {
  final int? rank;
  final String userId;
  final String displayName;
  final String? avatarUrl;
  final double totalAreaSqm;

  RankingEntry({
    this.rank,
    required this.userId,
    required this.displayName,
    this.avatarUrl,
    required this.totalAreaSqm,
  });

  factory RankingEntry.fromJson(Map<String, dynamic> json) {
    return RankingEntry(
      rank: json['rank'],
      userId: json['userId'],
      displayName: json['displayName'] ?? 'Unknown',
      avatarUrl: json['avatarUrl'],
      totalAreaSqm: (json['totalAreaSqm'] as num).toDouble(),
    );
  }
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
