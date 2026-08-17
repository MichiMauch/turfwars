import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/territory.dart';
import '../providers/game_provider.dart';
import '../utils/format.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<GameProvider>().loadStats();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meine Statistik'),
        backgroundColor: const Color(0xFF1B5E20),
        foregroundColor: Colors.white,
      ),
      body: Consumer<GameProvider>(
        builder: (context, game, _) {
          final stats = game.stats;

          if (stats == null) {
            return Center(
              child: game.isLoading
                  ? const CircularProgressIndicator()
                  : Text(
                      game.error ?? 'Noch keine Daten.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
            );
          }

          return RefreshIndicator(
            onRefresh: game.loadStats,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SummaryGrid(stats: stats),
                if (stats.pathSharePercent != null) ...[
                  const SizedBox(height: 12),
                  _PathShareCard(percent: stats.pathSharePercent!),
                ],
                const SizedBox(height: 24),
                for (final level in const [
                  'municipality',
                  'district',
                  'canton',
                  'country',
                ])
                  ..._levelSection(stats.onLevel(level), level),
                if (stats.regions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'Deine Gebiete liegen in keiner erfassten Region.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _levelSection(List<RegionHolding> holdings, String level) {
    if (holdings.isEmpty) return const [];

    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 8),
        child: Text(
          levelLabel(level),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.grey,
            letterSpacing: 1,
          ),
        ),
      ),
      for (final holding in holdings) _RegionCard(holding: holding),
      const SizedBox(height: 8),
    ];
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.stats});

  final PlayerStats stats;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.6,
      children: [
        _StatTile(
          icon: Icons.map,
          label: 'Gebiete',
          value: '${stats.territoryCount}',
        ),
        _StatTile(
          icon: Icons.crop_square,
          label: 'Gesamtfläche',
          value: formatArea(stats.totalAreaSqm),
        ),
        _StatTile(
          icon: Icons.star,
          label: 'Grösstes Gebiet',
          value: formatArea(stats.largestAreaSqm),
        ),
        _StatTile(
          icon: Icons.directions_walk,
          label: 'Erlaufen',
          value: formatDistance(stats.totalDistanceM),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: const Color(0xFF1B5E20), size: 22),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _RegionCard extends StatelessWidget {
  const _RegionCard({required this.holding});

  final RegionHolding holding;

  @override
  Widget build(BuildContext context) {
    final percent = holding.sharePercent;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  holding.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (holding.rank != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: holding.rank == 1
                        ? Colors.amber.shade100
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Rang ${holding.rank}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            formatArea(holding.areaSqm),
            style: const TextStyle(fontSize: 15),
          ),
          if (percent != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                // Sehr kleine Anteile bekommen einen sichtbaren Rest
                value: (percent / 100).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: Colors.grey.shade200,
                valueColor: const AlwaysStoppedAnimation(Color(0xFF2E7D32)),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${formatPercent(percent)} von ${formatArea(holding.regionAreaSqm ?? 0)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }
}

/// Wie viel der eigenen Walks auf erfassten Wegen lag. Bewusst ohne Wertung
/// dargestellt — abseits der Wege zu gehen ist in Wald und Weide erlaubt.
class _PathShareCard extends StatelessWidget {
  const _PathShareCard({required this.percent});

  final double percent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.route, size: 20, color: Color(0xFF1B5E20)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Auf erfassten Wegen',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${percent.toStringAsFixed(0)} %',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1B5E20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (percent / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: Colors.grey.shade200,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF2E7D32)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Nach Fläche gewichtet. Wald und Weide darfst du betreten — '
            'nimm einfach Rücksicht auf Kulturland und Wild.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}
