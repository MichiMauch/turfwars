import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../providers/game_provider.dart';
import '../utils/format.dart';
import 'ranking_screen.dart';
import 'stats_screen.dart';

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
    // Only worth interrupting for when there is nothing to play in — the
    // municipality itself is shown in the header, it needs no confirmation
    if (!_welcomeShown &&
        _provider!.municipalityDetected &&
        _provider!.currentMunicipality == null) {
      _showWelcomeSheet(_provider!);
    }

    final lost = _provider!.lostAreaSqm;
    if (lost != null && mounted) {
      _provider!.clearLoss();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
          content: Row(
            children: [
              const Icon(Icons.trending_down, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Dir wurden ${formatArea(lost)} abgenommen.',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  void _showWelcomeSheet(GameProvider provider) {
    if (_welcomeShown) return;
    _welcomeShown = true;

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        {
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
                        holePointsList: t.holes.isEmpty ? null : t.holes,
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
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                game.displayName ?? 'Turf Wars',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Row(
                                children: [
                                  Icon(Icons.place,
                                      size: 13, color: Colors.grey.shade600),
                                  const SizedBox(width: 2),
                                  Flexible(
                                    child: Text(
                                      game.currentMunicipality?.name ??
                                          (game.municipalityDetected
                                              ? 'Ausserhalb der Schweiz'
                                              : 'Standort wird gesucht …'),
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        // Stats button
                        IconButton(
                          icon: const Icon(Icons.insights),
                          tooltip: 'Meine Statistik',
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const StatsScreen(),
                              ),
                            );
                          },
                        ),
                        // Ranking button
                        IconButton(
                          icon: const Icon(Icons.leaderboard),
                          tooltip: 'Rangliste',
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
                        // Nachladen fehlgeschlagen — kein Grund zur Panik,
                        // die Runde selbst ist davon unberührt
                        if (game.loadError != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.amber.shade300),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.cloud_off,
                                    size: 18, color: Colors.amber.shade900),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    game.loadError!,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.amber.shade900,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => game.loadTerritories(),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    minimumSize: const Size(0, 32),
                                  ),
                                  child: const Text('Erneut'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
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
                                    'Territorium erobert! ${formatArea(game.lastClaimedTerritory!.areaSqm)}',
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
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              _WalkStat(
                                icon: Icons.timer_outlined,
                                value: formatDuration(game.durationSec),
                              ),
                              _WalkStat(
                                icon: Icons.straighten,
                                value: formatDistance(game.totalDistanceM),
                              ),
                              _WalkStat(
                                icon: Icons.speed,
                                value:
                                    '${game.currentSpeedKmh.toStringAsFixed(1)} km/h',
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
                                // Step 1: Choose user
                                if (!mounted) return;
                                List<dynamic> devUsers = [];
                                try {
                                  devUsers = await game.getDevUsers();
                                } catch (_) {}

                                if (!mounted) return;
                                // Use '_self_' sentinel to distinguish "eingeloggt" from dialog dismiss
                                final selectedUser = await showDialog<Object>(
                                  context: context,
                                  builder: (ctx) => SimpleDialog(
                                    title: const Text('User wählen'),
                                    children: [
                                      SimpleDialogOption(
                                        onPressed: () => Navigator.pop(ctx, '_self_'),
                                        child: Text('${game.displayName ?? "Ich"} (eingeloggt)'),
                                      ),
                                      ...devUsers.map((u) {
                                        final user = u as Map<String, dynamic>;
                                        return SimpleDialogOption(
                                          onPressed: () => Navigator.pop(ctx, user),
                                          child: Text(user['displayName'] ?? user['id']),
                                        );
                                      }),
                                    ],
                                  ),
                                );
                                // Dialog dismissed = cancelled
                                if (selectedUser == null || !mounted) return;

                                if (selectedUser is Map<String, dynamic>) {
                                  game.setSimulatedUser(
                                    selectedUser['id'],
                                    selectedUser['displayName'],
                                  );
                                } else {
                                  game.setSimulatedUser(null, null);
                                }

                                // Step 2: Choose walk
                                final walks = GameProvider.testWalks;
                                if (!mounted) return;
                                final selected = await showDialog<String>(
                                  context: context,
                                  builder: (ctx) => SimpleDialog(
                                    title: Text(
                                      'Test Walk starten${game.simulatedUserName != null ? ' (als ${game.simulatedUserName})' : ''}',
                                    ),
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
                                } else {
                                  game.setSimulatedUser(null, null);
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

/// Eine Kennzahl im Lauf-Panel: Symbol plus Wert.
class _WalkStat extends StatelessWidget {
  const _WalkStat({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: Colors.black54),
        const SizedBox(width: 5),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}
