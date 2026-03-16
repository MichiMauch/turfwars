import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../models/territory.dart';

class TerritoryPolygonWidget extends StatelessWidget {
  final Territory territory;
  final bool isOwn;

  const TerritoryPolygonWidget({
    super.key,
    required this.territory,
    required this.isOwn,
  });

  @override
  Widget build(BuildContext context) {
    return PolygonLayer(
      polygons: [
        Polygon(
          points: territory.polygon,
          color: isOwn
              ? Colors.green.withValues(alpha: 0.3)
              : Colors.red.withValues(alpha: 0.2),
          borderColor: isOwn ? Colors.green : Colors.red,
          borderStrokeWidth: 2,
          label: territory.displayName,
          labelStyle: TextStyle(
            color: isOwn ? Colors.green.shade900 : Colors.red.shade900,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
