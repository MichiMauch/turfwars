import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/game_provider.dart';
import '../utils/format.dart';

class RankingScreen extends StatefulWidget {
  const RankingScreen({super.key});

  @override
  State<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends State<RankingScreen> {
  @override
  void initState() {
    super.initState();
    final game = context.read<GameProvider>();
    if (game.regions.isNotEmpty && game.selectedRegionId == null) {
      // Auto-select first municipality
      final municipality = game.regions
          .where((r) => r.level == 'municipality')
          .toList();
      if (municipality.isNotEmpty) {
        game.loadRankings(municipality.first.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rankings'),
        backgroundColor: const Color(0xFF1B5E20),
        foregroundColor: Colors.white,
      ),
      body: Consumer<GameProvider>(
        builder: (context, game, _) {
          return Column(
            children: [
              // Region selector
              if (game.regions.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<String>(
                    decoration: InputDecoration(
                      labelText: 'Region',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    initialValue: game.selectedRegionId,
                    items: game.regions.map((r) {
                      final label = levelLabel(r.level);
                      return DropdownMenuItem(
                        value: r.id,
                        child: Text('${r.name} ($label)'),
                      );
                    }).toList(),
                    onChanged: (regionId) {
                      if (regionId != null) {
                        game.loadRankings(regionId);
                      }
                    },
                  ),
                ),

              if (game.regions.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No regions available yet. Regions will appear once admin boundaries are loaded.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),

              // Rankings list
              Expanded(
                child: game.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : game.rankings.isEmpty
                        ? const Center(
                            child: Text(
                              'No rankings yet.\nStart walking to claim territory!',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(fontSize: 16, color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount: game.rankings.length,
                            itemBuilder: (context, index) {
                              final entry = game.rankings[index];
                              final isMe = entry.userId == game.userId;

                              return Container(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 16),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? Colors.green.shade50
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: isMe
                                      ? Border.all(
                                          color: Colors.green, width: 2)
                                      : null,
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.05),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    _buildRankBadge(entry.rank ?? index + 1),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  entry.displayName,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: isMe
                                                        ? FontWeight.bold
                                                        : FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              if (isMe) ...[
                                                const SizedBox(width: 6),
                                                const Icon(Icons.person,
                                                    size: 18,
                                                    color: Colors.green),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${entry.territoryCount} '
                                            '${entry.territoryCount == 1 ? "Gebiet" : "Gebiete"}',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      formatArea(entry.totalAreaSqm),
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1B5E20),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRankBadge(int rank) {
    Color color;
    IconData? icon;

    switch (rank) {
      case 1:
        color = Colors.amber;
        icon = Icons.emoji_events;
        break;
      case 2:
        color = Colors.grey.shade400;
        icon = Icons.emoji_events;
        break;
      case 3:
        color = Colors.brown.shade300;
        icon = Icons.emoji_events;
        break;
      default:
        color = Colors.grey.shade200;
        icon = null;
    }

    return CircleAvatar(
      radius: 24,
      backgroundColor: color,
      child: icon != null
          ? Icon(icon, color: Colors.white, size: 26)
          : Text(
              '$rank',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
    );
  }
}
