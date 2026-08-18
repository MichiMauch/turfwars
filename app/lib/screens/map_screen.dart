import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../providers/game_provider.dart';
import '../services/pending_loop.dart';
import 'login_screen.dart';
import '../utils/format.dart';
import 'ranking_screen.dart';
import 'stats_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  bool _welcomeShown = false;
  GameProvider? _provider;

  /// Beim Verschieben feuert onPositionChanged pro Frame. Ohne Entprellung
  /// wäre das eine Anfrage je Bildaufbau.
  Timer? _boundsDebounce;

  /// Runden, für die schon einmal ungefragt ein Dialog aufging. Ohne das
  /// würde ein fehlgeschlagener Claim den Dialog sofort wieder öffnen, weil
  /// der Eintrag ja liegen bleibt. Über den Hinweisstreifen ist er weiter
  /// erreichbar.
  final Set<String> _askedLoopIds = {};
  bool _loopDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider = context.read<GameProvider>();
      if (_provider!.currentPosition != null) {
        _mapController.move(_provider!.currentPosition!, 15);
      }
      // Der Startkasten aus initialize() ist geraten — sobald die Karte steht,
      // zählt ihr tatsächlicher Ausschnitt.
      _loadVisibleTerritories();
      // Runden aus einem früheren Lauf werden schon beim Anmelden geladen,
      // also bevor es diesen Bildschirm gibt. Ohne das hier bliebe die Frage
      // nach einem Neustart aus der Benachrichtigung unbeantwortet stehen.
      _maybeAskAboutLoop();
      // Listen for municipality detection to show welcome dialog
      _provider!.addListener(_onProviderChanged);
    });
  }

  void _onMapMoved() {
    _boundsDebounce?.cancel();
    _boundsDebounce = Timer(
      const Duration(milliseconds: 500),
      _loadVisibleTerritories,
    );
  }

  void _loadVisibleTerritories() {
    if (!mounted || _provider == null) return;
    final bounds = _mapController.camera.visibleBounds;
    _provider!.loadTerritoriesIn(
      minLng: bounds.west,
      minLat: bounds.south,
      maxLng: bounds.east,
      maxLat: bounds.north,
    );
  }

  void _onProviderChanged() {
    if (_provider == null) return;

    if (_provider!.sessionExpired) {
      _returnToLogin();
      return;
    }

    _maybeAskAboutLoop();

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

  /// Der Token liess sich nicht mehr erneuern. Zurück zum Anmeldebildschirm —
  /// eine Karte, auf der jeder Aufruf scheitert, sieht angemeldet aus und ist
  /// es nicht.
  ///
  /// Ein laufender Lauf überlebt das: der GameProvider hängt an der Wurzel der
  /// App (main.dart) und damit über dieser Navigation, die Spur bleibt also
  /// samt Aufzeichnung bestehen.
  void _returnToLogin() {
    if (!mounted) return;
    _provider!.clearSessionExpired();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: const Text(
          'Sitzung abgelaufen. Bitte neu anmelden — der Lauf läuft weiter.',
          style: TextStyle(color: Colors.white),
        ),
      ),
    );

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  /// Fragt ungefragt nach der ältesten Runde, die noch keine Antwort hat.
  void _maybeAskAboutLoop() {
    if (!mounted || _loopDialogOpen || _provider == null) return;

    PendingLoop? next;
    for (final loop in _provider!.pendingLoops) {
      if (!_askedLoopIds.contains(loop.id)) {
        next = loop;
        break;
      }
    }
    if (next == null) return;

    _askedLoopIds.add(next.id);
    _askAboutLoop(next);
  }

  Future<void> _askAboutLoop(PendingLoop loop) async {
    _loopDialogOpen = true;

    final claim = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.flag, color: Color(0xFF1B5E20), size: 32),
        title: const Text('Runde geschlossen'),
        content: Text(
          'Du hast ${formatArea(loop.areaSqm)} umrundet. '
          'Als Gebiet beanspruchen?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Verwerfen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Beanspruchen'),
          ),
        ],
      ),
    );

    _loopDialogOpen = false;
    if (!mounted || claim == null) return;

    if (claim) {
      await _confirmLoop(loop);
    } else {
      await _provider!.discardPendingLoop(loop.id);
    }
  }

  Future<void> _confirmLoop(PendingLoop loop) async {
    final ok = await _provider!.confirmPendingLoop(loop.id);
    if (!mounted || ok) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text(
          _provider!.error ?? 'Gebiet konnte nicht beansprucht werden.',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  /// Fragt, als welcher Spieler der nächste simulierte Lauf zählt.
  /// Gibt false zurück, wenn abgebrochen wurde.
  Future<bool> _chooseSimulatedUser(GameProvider game) async {
    List<dynamic> devUsers = [];
    try {
      devUsers = await game.getDevUsers();
    } catch (_) {
      // Ohne Dev-Nutzer bleibt die Auswahl auf den eigenen Account beschränkt.
    }
    if (!mounted) return false;

    // '_self_' unterscheidet "eingeloggt gewählt" von "Dialog weggetippt".
    final selected = await showDialog<Object>(
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

    if (selected == null || !mounted) return false;

    if (selected is Map<String, dynamic>) {
      game.setSimulatedUser(selected['id'], selected['displayName']);
    } else {
      game.setSimulatedUser(null, null);
    }
    return true;
  }

  /// Spielt die zuletzt gezeichnete Route nochmal ab, als jemand anderes.
  Future<void> _replayRoute(GameProvider game) async {
    if (!await _chooseSimulatedUser(game)) return;
    if (!mounted) return;

    final asWho = game.simulatedUserName ?? game.displayName ?? 'dir';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text('Route läuft nochmal — als $asWho.'),
      ),
    );
    await game.replayLastRoute();
  }

  Future<void> _startDrawing(GameProvider game) async {
    if (!await _chooseSimulatedUser(game)) return;
    if (!mounted) return;

    game.startDrawingRoute();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(
          'Punkte antippen, dann auf Abspielen. Die Route wird zum Schluss '
          'automatisch geschlossen.'
          '${game.simulatedUserName != null ? " Als ${game.simulatedUserName}." : ""}',
        ),
      ),
    );
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Antippen der Benachrichtigung holt die App nach vorn — dann soll die
    // Frage anliegen, ohne dass erst irgendetwas anderes passieren muss.
    if (state == AppLifecycleState.resumed) _maybeAskAboutLoop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _boundsDebounce?.cancel();
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
                  onPositionChanged: (_, _) => _onMapMoved(),
                  onTap: (_, point) => game.addRoutePoint(point),
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

                  // Gezeichnete Route (Entwicklermodus)
                  if (game.drawnRoute.isNotEmpty) ...[
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: game.drawnRoute.length > 2
                              // Schliessend anzeigen, weil sie beim Abspielen
                              // auch geschlossen wird — sonst sieht man nicht,
                              // welche Fläche man gerade umrundet.
                              ? [...game.drawnRoute, game.drawnRoute.first]
                              : game.drawnRoute,
                          color: Colors.deepOrange,
                          strokeWidth: 3,
                          pattern: StrokePattern.dashed(segments: const [8, 6]),
                        ),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        for (int i = 0; i < game.drawnRoute.length; i++)
                          Marker(
                            point: game.drawnRoute[i],
                            width: 22,
                            height: 22,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.deepOrange,
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 2),
                              ),
                              child: Text(
                                '${i + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],

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
                        // Runden, die auf eine Antwort warten. Der Dialog geht
                        // je Runde nur einmal von selbst auf — hierüber bleibt
                        // sie danach erreichbar.
                        for (final loop in game.pendingLoops) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.blue.shade300),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.flag, color: Colors.blue.shade700),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Runde offen: ${formatArea(loop.areaSqm)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: game.isLoading
                                      ? null
                                      : () => _askAboutLoop(loop),
                                  child: const Text('Entscheiden'),
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
                      // Tempo. Beim Fehlersuchen will man schnell durch, beim
                      // Zuschauen langsam.
                      if (!game.drawingRoute)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            elevation: 4,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (final speed
                                      in GameProvider.simulationSpeeds)
                                    InkWell(
                                      onTap: () =>
                                          game.setSimulationSpeed(speed),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        child: Text(
                                          '${speed}x',
                                          style: TextStyle(
                                            fontWeight:
                                                game.simulationSpeed == speed
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                            color: game.simulationSpeed == speed
                                                ? Colors.deepOrange
                                                : Colors.black54,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),

                      // Route zeichnen: antippen, schliessen, abspielen
                      if (game.drawingRoute) ...[
                        // Was gerade umrundet wird. Die Schwellen der
                        // Loop-Erkennung sind auf der Karte sonst unsichtbar.
                        if (game.drawnRoute.length >= 3)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: game.drawnRouteIsWalkable
                                  ? Colors.green.shade700
                                  : Colors.orange.shade800,
                              borderRadius: BorderRadius.circular(12),
                              elevation: 4,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                child: Text(
                                  '${formatDistance(game.drawnRouteLengthM)}\n'
                                  '${formatArea(game.drawnRouteAreaSqm)}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        FloatingActionButton.small(
                          heroTag: 'draw_play',
                          backgroundColor: Colors.green.shade700,
                          onPressed: game.drawnRouteIsWalkable
                              ? () => game.simulateDrawnRoute()
                              : null,
                          child: const Icon(Icons.play_arrow,
                              color: Colors.white),
                        ),
                        const SizedBox(height: 8),
                        FloatingActionButton.small(
                          heroTag: 'draw_undo',
                          backgroundColor: Colors.blueGrey,
                          onPressed: game.drawnRoute.isEmpty
                              ? null
                              : () => game.undoRoutePoint(),
                          child: const Icon(Icons.undo, color: Colors.white),
                        ),
                        const SizedBox(height: 8),
                        FloatingActionButton.small(
                          heroTag: 'draw_cancel',
                          backgroundColor: Colors.red,
                          onPressed: () => game.cancelDrawingRoute(),
                          child: const Icon(Icons.close, color: Colors.white),
                        ),
                        const SizedBox(height: 8),
                      ] else if (!game.isSimulating) ...[
                        // Dieselbe Route als anderer Spieler. Zwei von Hand
                        // getippte Ringe sind nie deckungsgleich — für eine
                        // saubere Übernahme muss es derselbe sein.
                        if (game.hasLastRoute) ...[
                          FloatingActionButton.small(
                            heroTag: 'draw_replay',
                            backgroundColor: Colors.indigo,
                            onPressed: game.isLoading
                                ? null
                                : () => _replayRoute(game),
                            child: const Icon(Icons.replay,
                                color: Colors.white),
                          ),
                          const SizedBox(height: 8),
                        ],
                        FloatingActionButton.small(
                          heroTag: 'draw_start',
                          backgroundColor: Colors.deepOrange.shade300,
                          onPressed: game.isLoading
                              ? null
                              : () => _startDrawing(game),
                          child: const Icon(Icons.edit, color: Colors.white),
                        ),
                        const SizedBox(height: 8),
                      ],
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
                                if (!await _chooseSimulatedUser(game)) return;

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
