import 'package:flutter/material.dart';
import '../models/player.dart';
import '../services/player_service.dart';
import 'add_player_screen.dart';

class RosterScreen extends StatefulWidget {
  final String teamId;

  const RosterScreen({super.key, required this.teamId});

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> {
  final _playerService = PlayerService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Roster'),
        centerTitle: true,
      ),
      body: StreamBuilder<List<Player>>(
        stream: _playerService.getPlayerStream(widget.teamId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final players = snapshot.data ?? [];

          if (players.isEmpty) {
            return const Center(
              child: Text('No players found. Tap + to add one!'),
            );
          }

          return ListView.builder(
            itemCount: players.length,
            itemBuilder: (context, index) {
              final player = players[index];

              // Swipe-to-Delete Wrapper
              return Dismissible(
                key: Key(player.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (direction) async {
                  await _playerService.deletePlayer(player.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${player.displayName} removed')),
                    );
                  }
                },
                child: Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text(player.jerseyNumber?.toString() ?? '#'),
                    ),
                    title: Text(player.displayName),
                    subtitle: Text(
                      (player.nickname != null && player.nickname!.isNotEmpty)
                          ? '"${player.nickname}"'
                          : (player.position ?? 'General'),
                    ),
                    trailing: const Icon(Icons.edit_outlined, size: 20),
                    onTap: () {
                      // Navigate to Edit Mode
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => AddPlayerScreen(
                            teamId: widget.teamId,
                            playerToEdit: player,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Navigate to Add Mode
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AddPlayerScreen(teamId: widget.teamId),
            ),
          );
        },
        child: const Icon(Icons.person_add),
      ),
    );
  }
}