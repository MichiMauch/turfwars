import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/game_provider.dart';

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
                      final levelLabel = _levelLabel(r.level);
                      return DropdownMenuItem(
                        value: r.id,
                        child: Text('${r.name} ($levelLabel)'),
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
                                    horizontal: 16, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? Colors.green.shade50
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: isMe
                                      ? Border.all(
                                          color: Colors.green, width: 2)
                                      : null,
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.05),
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                                child: ListTile(
                                  leading: _buildRankBadge(
                                      entry.rank ?? index + 1),
                                  title: Text(
                                    entry.displayName,
                                    style: TextStyle(
                                      fontWeight: isMe
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                  subtitle: Text(_formatArea(entry.totalAreaSqm)),
                                  trailing: isMe
                                      ? const Icon(Icons.person,
                                          color: Colors.green)
                                      : null,
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
      backgroundColor: color,
      child: icon != null
          ? Icon(icon, color: Colors.white, size: 20)
          : Text(
              '$rank',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
    );
  }

  String _formatArea(double sqm) {
    if (sqm >= 1000000) {
      return '${(sqm / 1000000).toStringAsFixed(2)} km²';
    } else if (sqm >= 10000) {
      return '${(sqm / 10000).toStringAsFixed(1)} ha';
    }
    return '${sqm.toStringAsFixed(0)} m²';
  }

  String _levelLabel(String level) {
    switch (level) {
      case 'municipality':
        return 'Gemeinde';
      case 'district':
        return 'Bezirk';
      case 'canton':
        return 'Kanton';
      case 'country':
        return 'Land';
      default:
        return level;
    }
  }
}
