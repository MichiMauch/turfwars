import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/territory.dart';
import '../providers/game_provider.dart';
import '../utils/format.dart';
import '../utils/rank_colors.dart';

class RankingScreen extends StatefulWidget {
  const RankingScreen({super.key});

  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  String? _level;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final game = context.read<GameProvider>();
      final regions = game.rankingRegions;
      if (regions.isEmpty) return;

      final start = regions.first;
      setState(() => _level = start.level);
      if (game.selectedRegionId != start.id) {
        game.loadRankings(start.id);
      }
    });
  }

  RegionHolding? _regionFor(List<RegionHolding> regions, String? level) {
    for (final region in regions) {
      if (region.level == level) return region;
    }
    return regions.isEmpty ? null : regions.first;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(title: const Text('Rangliste')),
      body: Consumer<GameProvider>(
        builder: (context, game, _) {
          final regions = game.rankingRegions;
          final current = _regionFor(regions, _level);

          if (current == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  game.isLoading
                      ? 'Wird geladen …'
                      : 'Noch keine Region. Sobald dein Standort bekannt ist '
                          'oder du ein Gebiet besitzt, erscheint hier eine Rangliste.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            );
          }

          return Column(
            children: [
              _RegionHeader(region: current),
              if (regions.length > 1)
                _LevelSwitcher(
                  regions: regions,
                  selected: current.level,
                  onSelect: (region) {
                    setState(() => _level = region.level);
                    game.loadRankings(region.id);
                  },
                ),
              Expanded(
                child: game.isLoading && game.rankings.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : game.rankings.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                'In ${current.name} hat noch niemand Gebiet '
                                'beansprucht. Lauf eine Runde!',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: () => game.loadRankings(current.id),
                            child: ListView.builder(
                              padding: const EdgeInsets.only(top: 8, bottom: 24),
                              itemCount: game.rankings.length,
                              itemBuilder: (context, index) => _RankingRow(
                                entry: game.rankings[index],
                                fallbackRank: index + 1,
                                isMe: game.rankings[index].userId == game.userId,
                              ),
                            ),
                          ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RegionHeader extends StatelessWidget {
  const _RegionHeader({required this.region});

  final RegionHolding region;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: scheme.primary,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            levelLabel(region.level).toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.2,
              color: scheme.onPrimary.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            region.name,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: scheme.onPrimary,
            ),
          ),
          if (region.rank != null) ...[
            const SizedBox(height: 8),
            Text(
              'Du bist auf Rang ${region.rank} '
              'mit ${formatArea(region.areaSqm)}'
              '${region.sharePercent != null ? ' — ${formatPercent(region.sharePercent!)}' : ''}',
              style: TextStyle(
                fontSize: 14,
                color: scheme.onPrimary.withValues(alpha: 0.9),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LevelSwitcher extends StatelessWidget {
  const _LevelSwitcher({
    required this.regions,
    required this.selected,
    required this.onSelect,
  });

  final List<RegionHolding> regions;
  final String selected;
  final ValueChanged<RegionHolding> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          for (final region in regions) ...[
            ChoiceChip(
              label: Text(levelLabel(region.level)),
              selected: region.level == selected,
              onSelected: (_) => onSelect(region),
              selectedColor: scheme.primary,
              labelStyle: TextStyle(
                color: region.level == selected
                    ? scheme.onPrimary
                    : scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _RankingRow extends StatelessWidget {
  const _RankingRow({
    required this.entry,
    required this.fallbackRank,
    required this.isMe,
  });

  final RankingEntry entry;
  final int fallbackRank;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: isMe ? scheme.primaryContainer : scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: isMe ? Border.all(color: scheme.primary, width: 2) : null,
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.05),
            blurRadius: 6,
          ),
        ],
      ),
      child: Row(
        children: [
          _RankBadge(rank: entry.rank ?? fallbackRank),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight:
                              isMe ? FontWeight.bold : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.person, size: 18, color: scheme.primary),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${entry.territoryCount} '
                  '${entry.territoryCount == 1 ? "Gebiet" : "Gebiete"}',
                  style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            formatArea(entry.totalAreaSqm),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return CircleAvatar(
      radius: 24,
      backgroundColor: medalColor(rank),
      child: isPodium(rank)
          ? Icon(Icons.emoji_events, color: scheme.onPrimary, size: 26)
          : Text(
              '$rank',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: scheme.onSurface,
              ),
            ),
    );
  }
}
