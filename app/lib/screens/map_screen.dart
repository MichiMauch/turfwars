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
  bool _welcomeShown = false;
  GameProvider? _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider = context.read<GameProvider>();
      if (_provider!.currentPosition != null) {
        _mapController.move(_provider!.currentPosition!, 15);
      }
      // Listen for municipality detection to show welcome dialog
      _provider!.addListener(_onProviderChanged);
    });
  }

  void _onProviderChanged() {
    if (_provider == null) return;
    if (!_welcomeShown && !_provider!.municipalityConfirmed && _provider!.municipalityDetected) {
      _showWelcomeSheet(_provider!);
    }
  }

  void _showWelcomeSheet(GameProvider provider) {
    if (_welcomeShown) return;
    _welcomeShown = true;

    final municipality = provider.currentMunicipality;

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        if (municipality != null) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.location_on, size: 48, color: Color(0xFF1B5E20)),
                const SizedBox(height: 12),
                Text(
                  'Willkommen!',
                  style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Du bist in ${municipality.name}',
                  style: Theme.of(ctx).textTheme.bodyLarge,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      provider.confirmMunicipality();
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: Text('In ${municipality.name} spielen'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B5E20),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        } else {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.location_off, size: 48, color: Colors.grey),
                const SizedBox(height: 12),
                Text(
                  'Nicht unterstützte Region',
                  style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Du bist nicht in einer unterstützten Gemeinde. '
                  'Bewege dich in die Schweiz, um zu spielen.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _welcomeShown = false; // Allow retry
                    },
                    child: const Text('Schliessen'),
                  ),
                ),
              ],
            ),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _provider?.removeListener(_onProviderChanged);
    super.dispose();
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
                  minZoom: 3,
                  maxZoom: 19,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'ch.turfwars.app',
                    maxZoom: 19,
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

                  // Track head marker (current position on track)
                  if (game.currentTrack.isNotEmpty)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: game.currentTrack.last,
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

              // Tracking status & start button
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
                        // Error message
                        if (game.error != null && !game.isTracking) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.red.shade300),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.error_outline, color: Colors.red.shade700),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    game.error!,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: Colors.red.shade700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        // Auto-claim success message
                        if (game.lastClaimedTerritory != null) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.green.shade300),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.check_circle, color: Colors.green.shade700),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Territorium erobert! ${game.lastClaimedTerritory!.areaSqm.toStringAsFixed(0)} m²',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: Colors.green.shade700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        // Auto-claim pending
                        if (game.autoClaimPending) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Loop erkannt! Territorium wird beansprucht...',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (game.isTracking) ...[
                          Row(
                            children: [
                              const Icon(Icons.gps_fixed, color: Colors.blue),
                              const SizedBox(width: 8),
                              Text(
                                'Tracking... ${game.currentTrack.length} Punkte',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black87,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(Icons.speed,
                                  size: 18, color: Colors.black54),
                              const SizedBox(width: 4),
                              Text(
                                '${game.currentSpeedKmh.toStringAsFixed(1)} km/h',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.black54,
                                ),
                              ),
                              const SizedBox(width: 24),
                              const Icon(Icons.straighten,
                                  size: 18, color: Colors.black54),
                              const SizedBox(width: 4),
                              Text(
                                game.totalDistanceM >= 1000
                                    ? '${(game.totalDistanceM / 1000).toStringAsFixed(1)} km'
                                    : '${game.totalDistanceM.toStringAsFixed(0)} m',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                        SizedBox(
                          width: double.infinity,
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
                      ],
                    ),
                  ),
                ),
              ),

              // Debug: simulate walk / claim buttons
              Positioned(
                top: 100,
                right: 16,
                child: SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'debug_walk',
                        backgroundColor:
                            game.isSimulating ? Colors.red : Colors.deepOrange,
                        onPressed: game.isLoading
                            ? null
                            : () async {
                                if (game.isSimulating) {
                                  game.stopSimulation();
                                  return;
                                }
                                final walks = GameProvider.testWalks;
                                if (!mounted) return;
                                final selected = await showDialog<String>(
                                  context: context,
                                  builder: (ctx) => SimpleDialog(
                                    title: const Text('Test Walk starten'),
                                    children: walks.map((path) {
                                      final name = path.split('/').last
                                          .replaceAll('.gpx', '');
                                      return SimpleDialogOption(
                                        onPressed: () =>
                                            Navigator.pop(ctx, path),
                                        child: Text(name),
                                      );
                                    }).toList(),
                                  ),
                                );
                                if (selected != null) {
                                  game.simulateWalk(selected);
                                }
                              },
                        child: Icon(
                          game.isSimulating ? Icons.stop : Icons.directions_walk,
                          color: Colors.white,
                        ),
                      ),
                    ],
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
