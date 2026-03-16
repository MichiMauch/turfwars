import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../providers/game_provider.dart';
import '../services/location_service.dart';
import 'ranking_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<GameProvider>();
      if (provider.currentPosition != null) {
        _mapController.move(provider.currentPosition!, 15);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<GameProvider>(
        builder: (context, game, _) {
          return Stack(
            children: [
              // Map
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: game.currentPosition ??
                      const LatLng(47.3769, 8.5417), // Zurich default
                  initialZoom: 15,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'ch.turfwars.app',
                  ),

                  // Existing territories
                  PolygonLayer(
                    polygons: game.territories.map((t) {
                      final isOwn = t.userId == game.userId;
                      return Polygon(
                        points: t.polygon,
                        color: isOwn
                            ? Colors.green.withValues(alpha: 0.3)
                            : Colors.red.withValues(alpha: 0.2),
                        borderColor: isOwn ? Colors.green : Colors.red,
                        borderStrokeWidth: 2,
                        label: t.displayName,
                        labelStyle: TextStyle(
                          color: isOwn ? Colors.green.shade900 : Colors.red.shade900,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      );
                    }).toList(),
                  ),

                  // Current track
                  if (game.currentTrack.isNotEmpty)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: game.currentTrack,
                          color: Colors.blue,
                          strokeWidth: 4,
                        ),
                      ],
                    ),

                  // Start point marker
                  if (game.currentTrack.isNotEmpty)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: game.currentTrack.first,
                          width: 20,
                          height: 20,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                      ],
                    ),

                  // Current position marker
                  if (game.currentPosition != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: game.currentPosition!,
                          width: 24,
                          height: 24,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.blue.shade700,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withValues(alpha: 0.4),
                                  blurRadius: 8,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),

              // Top bar with user info
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.terrain,
                            color: Color(0xFF1B5E20), size: 28),
                        const SizedBox(width: 8),
                        Text(
                          game.displayName ?? 'Turf Wars',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const Spacer(),
                        // Ranking button
                        IconButton(
                          icon: const Icon(Icons.leaderboard),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const RankingScreen(),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Tracking status & claim button
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (game.isTracking) ...[
                          Row(
                            children: [
                              Icon(
                                game.trackingStatus ==
                                        TrackingStatus.loopDetected
                                    ? Icons.check_circle
                                    : Icons.gps_fixed,
                                color: game.trackingStatus ==
                                        TrackingStatus.loopDetected
                                    ? Colors.green
                                    : Colors.blue,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                game.trackingStatus ==
                                        TrackingStatus.loopDetected
                                    ? 'Loop detected! Claim your territory'
                                    : 'Tracking... ${game.currentTrack.length} points',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: game.trackingStatus ==
                                          TrackingStatus.loopDetected
                                      ? Colors.green
                                      : Colors.black87,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: game.isLoading
                                    ? null
                                    : () {
                                        if (!game.isTracking) {
                                          game.startTracking();
                                        } else {
                                          game.stopTracking();
                                        }
                                      },
                                icon: Icon(game.isTracking
                                    ? Icons.stop
                                    : Icons.play_arrow),
                                label: Text(game.isTracking
                                    ? 'Stop'
                                    : 'Start Walking'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: game.isTracking
                                      ? Colors.red
                                      : const Color(0xFF1B5E20),
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                            if (game.trackingStatus ==
                                TrackingStatus.loopDetected) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: game.isLoading
                                      ? null
                                      : () async {
                                          final success =
                                              await game.claimTerritory();
                                          if (success && mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                    'Territory claimed!'),
                                                backgroundColor: Colors.green,
                                              ),
                                            );
                                          } else if (game.error != null &&
                                              mounted) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(game.error!),
                                                backgroundColor: Colors.red,
                                              ),
                                            );
                                          }
                                        },
                                  icon: const Icon(Icons.flag),
                                  label: const Text('Claim!'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Loading overlay
              if (game.isLoading)
                const Center(
                  child: CircularProgressIndicator(),
                ),
            ],
          );
        },
      ),
    );
  }
}
