import 'package:flutter/material.dart';
import '../services/player_service.dart';
import 'roster_screen.dart';

class TeamSelectionScreen extends StatefulWidget {
  const TeamSelectionScreen({super.key});

  @override
  State<TeamSelectionScreen> createState() => _TeamSelectionScreenState();
}

class _TeamSelectionScreenState extends State<TeamSelectionScreen> {
  final _playerService = PlayerService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Your Team'), centerTitle: true),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _playerService.getTeams(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final teams = snapshot.data ?? [];

          if (teams.isEmpty) {
            return const Center(child: Text('No teams found. Tap the button to create one!'));
          }

          return ListView.builder(
            itemCount: teams.length,
            padding: const EdgeInsets.all(16),
            itemBuilder: (context, index) {
              final team = teams[index];
              return Card(
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: const Icon(Icons.group, color: Colors.blue),
                  title: Text(team['team_name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(team['sport'] ?? 'General'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => RosterScreen(teamId: team['id']),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateTeamDialog,
        label: const Text('New Team'),
        icon: const Icon(Icons.add),
      ),
    ); // <--- This was missing the closing parenthesis and semicolon
  }

  void _showCreateTeamDialog() {
    final nameController = TextEditingController();
    final sportController = TextEditingController(text: 'General');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Team'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Team Name (e.g. Tigers)'),
              autofocus: true,
            ),
            TextField(
              controller: sportController,
              decoration: const InputDecoration(labelText: 'Sport'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty) {
                await _playerService.createTeam(
                  nameController.text.trim(),
                  sportController.text.trim(),
                );
                if (mounted) {
                  Navigator.pop(context);
                  setState(() {}); // This re-runs the FutureBuilder to show the new team
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}