import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../models/territory.dart';
import '../providers/game_provider.dart';
import '../theme.dart';
import '../services/pending_loop.dart';
import 'login_screen.dart';
import '../utils/format.dart';
import '../utils/geo.dart';
import '../utils/player_colors.dart';
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

  /// Ob schon einmal auf den Standort zentriert wurde.
  ///
  /// Die Karte erscheint jetzt, bevor die Position da ist — sie startet also
  /// auf dem Ersatzmittelpunkt. Ohne das hier bliebe sie dort stehen: das
  /// Nachführen greift nur während eines Laufs.
  bool _centredOnce = false;

  /// Ob die Karte dem Standort folgt. Nur während der Aufzeichnung relevant —
  /// ohne Lauf gibt es keinen Positionsstream, dem man folgen könnte.
  bool _followPosition = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider = context.read<GameProvider>();
      if (_provider!.currentPosition != null) {
        _mapController.move(_provider!.currentPosition!, 15);
        _centredOnce = true;
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

  void _centreOnFirstPosition() {
    if (_centredOnce || !mounted || _provider == null) return;
    final position = _provider!.currentPosition;
    if (position == null) return;

    _centredOnce = true;
    _mapController.move(position, 15);
  }

  /// Schiebt die Karte auf den Standort, unabhängig davon ob gerade
  /// aufgezeichnet wird. Zoomstufe bleibt: mit einem festen Wert spränge die
  /// Karte bei jedem GPS-Punkt auf eine andere Stufe zurück.
  void _centreOnPosition() {
    if (!mounted || _provider == null) return;
    final position = _provider!.currentPosition;
    if (position == null) return;

    _mapController.move(position, _mapController.camera.zoom);
  }

  /// Das laufende Nachführen während einer Aufzeichnung. Ausserhalb eines
  /// Laufs kommen keine neuen Punkte, da gäbe es nichts nachzuführen.
  void _followCurrentPosition() {
    if (!_followPosition || _provider == null || !_provider!.isTracking) return;
    _centreOnPosition();
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
    final scheme = Theme.of(context).colorScheme;
    if (_provider == null) return;

    if (_provider!.sessionExpired) {
      _returnToLogin();
      return;
    }

    _maybeAskAboutLoop();
    _centreOnFirstPosition();
    _followCurrentPosition();

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
          backgroundColor: scheme.error,
          duration: const Duration(seconds: 5),
          content: Row(
            children: [
              Icon(Icons.trending_down, color: scheme.onPrimary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Dir wurden ${formatArea(lost)} abgenommen.',
                  style: TextStyle(color: scheme.onError),
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
    final scheme = Theme.of(context).colorScheme;
    if (!mounted) return;
    _provider!.clearSessionExpired();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: scheme.error,
        duration: const Duration(seconds: 6),
        content: Text(
          'Sitzung abgelaufen. Bitte neu anmelden — der Lauf läuft weiter.',
          style: TextStyle(color: scheme.onError),
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
    final scheme = Theme.of(context).colorScheme;
    _loopDialogOpen = true;

    final claim = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.flag, color: scheme.primary, size: 32),
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
    final scheme = Theme.of(context).colorScheme;
    final ok = await _provider!.confirmPendingLoop(loop.id);
    if (!mounted || ok) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: scheme.error,
        duration: const Duration(seconds: 6),
        content: Text(
          _provider!.error ?? 'Gebiet konnte nicht beansprucht werden.',
          style: TextStyle(color: scheme.onError),
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
    final scheme = Theme.of(context).colorScheme;
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
                Icon(Icons.location_off, size: 48, color: scheme.onSurfaceVariant),
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
    final scheme = Theme.of(context).colorScheme;

    // Die Karte hat keine AppBar, also setzt niemand den Stil der Statusleiste
    // für sie. Kam man von der Rangliste zurück, blieb deren heller Stil
    // stehen — weisse Symbole auf hellem Grund, und die Uhr war weg. Eine
    // AnnotatedRegion setzt ihn jedes Mal neu, wenn diese Route obenauf liegt.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.statusBarOnPrimary,
      child: Scaffold(
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
                  onPositionChanged: (_, hasGesture) {
                    // Nur eigenes Schieben schaltet das Folgen ab. Die
                    // Bewegungen, die das Nachführen selbst auslöst, dürfen es
                    // nicht abwürgen.
                    if (hasGesture && _followPosition) {
                      setState(() => _followPosition = false);
                    }
                    _onMapMoved();
                  },
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
                  _TerritoryLayers(
                    territories: game.territories,
                    ownUserId: game.userId,
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
                          color: scheme.devTool,
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
                                color: scheme.devTool,
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: scheme.surface, width: 2),
                              ),
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(
                                  color: scheme.surface,
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
                          color: scheme.primary,
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
                              color: scheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: scheme.surface, width: 2),
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
                              color: scheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: scheme.surface, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: scheme.primary.withValues(alpha: 0.4),
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
                // Kein SafeArea: das Weiss reicht bis an die Bildschirmkante
                // und der Systemabstand wird zum Innenpolster. Sonst stünden
                // Uhrzeit und Symbole der Statusleiste auf den Kartenkacheln.
                child: Container(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      MediaQuery.paddingOf(context).top + 10,
                      16,
                      10,
                    ),
                    // Grün und ohne Rundung: der Kopfbereich gehört damit zum
                    // Fensterrahmen und nicht zur Karte. Eine gerundete weisse
                    // Karte sah aus wie ein drittes Element zwischen beidem.
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      boxShadow: [
                        BoxShadow(
                          color: scheme.shadow.withValues(alpha: 0.2),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        // Der Avatar ist der Einstieg ins Profil — das
                        // erwartet man heute dort, und er sagt zugleich, wer
                        // gerade angemeldet ist.
                        InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const StatsScreen(),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: playerColorFrom(game.myColor),
                                  width: 2,
                                ),
                              ),
                              child: CircleAvatar(
                                radius: 18,
                                backgroundColor: playerColorFrom(game.myColor),
                                foregroundImage: game.avatarUrl == null
                                    ? null
                                    : NetworkImage(game.avatarUrl!),
                                child: Icon(Icons.person,
                                    color: scheme.surface, size: 20),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                game.displayName ?? 'Turf Wars',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: scheme.onPrimary,
                                ),
                              ),
                              Row(
                                children: [
                                  Icon(Icons.place,
                                      size: 13,
                                      color: scheme.onPrimary
                                          .withValues(alpha: 0.8)),
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
                                        color: scheme.onPrimary
                                            .withValues(alpha: 0.8),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        // Rangliste. Pokal statt Balkendiagramm — zwei
                        // Diagrammsymbole nebeneinander liessen sich nicht
                        // auseinanderhalten.
                        IconButton(
                          tooltip: 'Rangliste',
                          icon: Icon(Icons.emoji_events,
                              color: scheme.onPrimary),
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

              // Tracking status & start button
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                // Der weisse Grund trägt Laufdaten und Meldungen — ohne ihn
                // lägen die unlesbar auf der Karte. Steht nur der Knopf da,
                // braucht es ihn nicht und die Karte gewinnt den Platz.
                child: Builder(builder: (context) {
                  final hasContent = game.loadError != null ||
                      (game.error != null && !game.isTracking) ||
                      game.lastClaimedTerritory != null ||
                      game.pendingLoops.isNotEmpty ||
                      game.isTracking;

                  return Container(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      hasContent ? 12 : 0,
                      16,
                      MediaQuery.paddingOf(context).bottom,
                    ),
                    decoration: BoxDecoration(
                      color: hasContent ? scheme.surface : Colors.transparent,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                      boxShadow: hasContent
                          ? [
                              BoxShadow(
                                color: scheme.shadow.withValues(alpha: 0.1),
                                blurRadius: 10,
                              ),
                            ]
                          : null,
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
                              color: scheme.noticeContainer,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: scheme.notice),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.cloud_off,
                                    size: 18, color: scheme.onNoticeContainer),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    game.loadError!,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: scheme.onNoticeContainer,
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
                              color: scheme.errorContainer,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: scheme.error),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.error_outline, color: scheme.error),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    game.error!,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: scheme.error,
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
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: scheme.primary),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.check_circle, color: scheme.primary),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Territorium erobert! ${formatArea(game.lastClaimedTerritory!.areaSqm)}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: scheme.primary,
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
                              color: scheme.noticeContainer,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: scheme.notice),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.flag, color: scheme.onNoticeContainer),
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
                              Icon(Icons.gps_fixed, color: scheme.primary),
                              const SizedBox(width: 8),
                              Text(
                                'Tracking... ${game.currentTrack.length} Punkte',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
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
                                      // Ein neuer Lauf beginnt wieder folgend,
                                      // auch wenn man im letzten selbst
                                      // herumgeschoben hat.
                                      setState(() => _followPosition = true);
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
                              backgroundColor:
                                  game.isTracking ? scheme.error : scheme.primary,
                              foregroundColor: scheme.onPrimary,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                ),

              // Debug: simulate walk / claim buttons
              Positioned(
                top: 100,
                right: 16,
                child: SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Zurück zum Standort. Immer sobald einer bekannt ist:
                      // die Karte wird auch ausserhalb eines Laufs verschoben,
                      // und dann führt ohne diesen Knopf nichts zurück.
                      if (game.currentPosition != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: FloatingActionButton.small(
                            heroTag: 'follow_position',
                            backgroundColor: scheme.primary,
                            onPressed: () {
                              setState(() => _followPosition = true);
                              _centreOnPosition();
                            },
                            child: Icon(Icons.my_location,
                                color: scheme.onPrimary),
                          ),
                        ),

                      // Alles ab hier ist Werkzeug zum Entwickeln.
                      if (game.devToolsVisible) ...[
                        // Tempo. Beim Fehlersuchen will man schnell durch, beim
                        // Zuschauen langsam.
                        if (!game.drawingRoute)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: scheme.surface,
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
                                                  ? scheme.devTool
                                                  : scheme.onSurfaceVariant,
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
                                    ? scheme.primary
                                    : scheme.notice,
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
                                    style: TextStyle(
                                      color: scheme.surface,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          FloatingActionButton.small(
                            heroTag: 'draw_play',
                            backgroundColor: scheme.primary,
                            onPressed: game.drawnRouteIsWalkable
                                ? () => game.simulateDrawnRoute()
                                : null,
                            child: Icon(Icons.play_arrow,
                                color: scheme.onPrimary),
                          ),
                          const SizedBox(height: 8),
                          FloatingActionButton.small(
                            heroTag: 'draw_undo',
                            backgroundColor: scheme.devTool,
                            onPressed: game.drawnRoute.isEmpty
                                ? null
                                : () => game.undoRoutePoint(),
                            child: Icon(Icons.undo, color: scheme.onPrimary),
                          ),
                          const SizedBox(height: 8),
                          FloatingActionButton.small(
                            heroTag: 'draw_cancel',
                            backgroundColor: scheme.error,
                            onPressed: () => game.cancelDrawingRoute(),
                            child: Icon(Icons.close, color: scheme.onPrimary),
                          ),
                          const SizedBox(height: 8),
                        ] else if (!game.isSimulating) ...[
                          // Dieselbe Route als anderer Spieler. Zwei von Hand
                          // getippte Ringe sind nie deckungsgleich — für eine
                          // saubere Übernahme muss es derselbe sein.
                          if (game.hasLastRoute) ...[
                            FloatingActionButton.small(
                              heroTag: 'draw_replay',
                              backgroundColor: scheme.devTool,
                              onPressed: game.isLoading
                                  ? null
                                  : () => _replayRoute(game),
                              child: Icon(Icons.replay,
                                  color: scheme.onPrimary),
                            ),
                            const SizedBox(height: 8),
                          ],
                          FloatingActionButton.small(
                            heroTag: 'draw_start',
                            backgroundColor: scheme.devTool,
                            onPressed: game.isLoading
                                ? null
                                : () => _startDrawing(game),
                            child: Icon(Icons.edit, color: scheme.onPrimary),
                          ),
                          const SizedBox(height: 8),
                        ],
                        FloatingActionButton.small(
                          heroTag: 'debug_walk',
                          backgroundColor:
                              game.isSimulating ? scheme.error : scheme.devTool,
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
                            color: scheme.surface,
                          ),
                        ),
                      ],
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
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

/// Die Gebiete: eingefärbte Flächen, und darauf Bild und Name des Besitzers.
///
/// Ein eigenes Widget und keine Liste in [_MapScreenState.build], weil die
/// Grössenprüfung die Kamera braucht. Über den MapController ist sie beim
/// ersten Aufbau noch nicht da — die children-Liste von FlutterMap wird
/// aufgebaut, bevor die Karte je gerendert hat. Aus dem Context heraus, also
/// als Kind der Karte, steht sie zuverlässig zur Verfügung.
class _TerritoryLayers extends StatelessWidget {
  const _TerritoryLayers({required this.territories, required this.ownUserId});

  final List<Territory> territories;
  final String? ownUserId;

  /// Kantenlänge in Pixeln, ab der ein Gebiet Bild und Name des Besitzers
  /// zeigt. Darunter würden die Schilder einander überdecken.
  static const double _minBadgePx = 90;

  /// Ob das Gebiet auf dem Bildschirm gross genug ist, Bild und Name zu tragen.
  ///
  /// Gemessen an der tatsächlichen Grösse in Pixeln, nicht an der Zoomstufe:
  /// ein grosses Gebiet trägt das Schild auch weit herausgezoomt, ein winziges
  /// auch nah dran nicht.
  static bool _fitsBadge(MapCamera camera, Territory territory) {
    if (territory.polygon.length < 3) return false;

    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;

    for (final point in territory.polygon) {
      final offset = camera.latLngToScreenOffset(point);
      if (offset.dx < minX) minX = offset.dx;
      if (offset.dx > maxX) maxX = offset.dx;
      if (offset.dy < minY) minY = offset.dy;
      if (offset.dy > maxY) maxY = offset.dy;
    }

    return (maxX - minX) >= _minBadgePx && (maxY - minY) >= _minBadgePx;
  }

  @override
  Widget build(BuildContext context) {

    final camera = MapCamera.of(context);
    final withBadge = <Territory>[];

    final polygons = <Polygon>[];
    for (final t in territories) {
      final isOwn = t.userId == ownUserId;
      final color = playerColorFrom(t.color);
      final fits = _fitsBadge(camera, t);
      if (fits) withBadge.add(t);

      // Die Farbe gehört jetzt dem Spieler, sie kann eigene Gebiete nicht mehr
      // kennzeichnen. Der Unterschied liegt in Deckkraft und Randstärke — wer
      // seine Farbe kennt, erkennt sie ohnehin, der Kontrast hilft beim
      // schnellen Blick.
      polygons.add(Polygon(
        points: t.polygon,
        holePointsList: t.holes.isEmpty ? null : t.holes,
        color: color.withValues(alpha: isOwn ? 0.38 : 0.18),
        borderColor: color,
        borderStrokeWidth: isOwn ? 3.5 : 1.5,
        // Der Name steht am Schild, sobald das Gebiet gross genug ist. Hier
        // nur für die kleinen, sonst stünde er doppelt.
        label: fits ? null : t.displayName,
        labelStyle: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ));
    }

    return Stack(
      children: [
        PolygonLayer(polygons: polygons),
        MarkerLayer(
          markers: [
            for (final t in withBadge)
              if (polygonCentroid(t.polygon) case final centre?)
                Marker(
                  point: centre,
                  width: 132,
                  height: 44,
                  child: _OwnerBadge(
                    name: t.displayName,
                    avatarUrl: t.avatarUrl,
                    color: playerColorFrom(t.color),
                    isOwn: t.userId == ownUserId,
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

/// Bild und Name des Besitzers, wie sie auf einem Gebiet stehen.
class _OwnerBadge extends StatelessWidget {
  const _OwnerBadge({
    required this.name,
    required this.avatarUrl,
    required this.color,
    required this.isOwn,
  });

  final String name;
  final String? avatarUrl;
  final Color color;
  final bool isOwn;

  /// Erste Buchstaben von bis zu zwei Namensteilen. Tritt an die Stelle des
  /// Bildes, wenn keines da ist oder es nicht lädt — ein leerer Kreis wäre
  /// schlechter als gar keiner.
  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: isOwn ? 3 : 2),
            color: scheme.surface,
          ),
          child: CircleAvatar(
            radius: 14,
            backgroundColor: color,
            foregroundImage:
                avatarUrl == null ? null : NetworkImage(avatarUrl!),
            // Liegt unter dem Bild und kommt zum Vorschein, wenn es fehlt oder
            // nicht lädt — foregroundImage blendet bei einem Fehler einfach aus.
            child: Text(
              _initials,
              style: TextStyle(
                color: scheme.surface,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: isOwn ? FontWeight.bold : FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
