import 'package:flutter/material.dart';
import '../services/player_service.dart';
import 'roster_screen.dart';
import 'login_screen.dart'; // ADD THIS IMPORT
import '../services/auth_service.dart';

class TeamSelectionScreen extends StatefulWidget {
  const TeamSelectionScreen({super.key});

  @override
  State<TeamSelectionScreen> createState() => _TeamSelectionScreenState();
}

class _TeamSelectionScreenState extends State<TeamSelectionScreen> {
  final _playerService = PlayerService();
  late Future<List<Map<String, dynamic>>> _teamsFuture;

  @override
  void initState() {
    super.initState();
    _refreshTeams();
  }

  void _refreshTeams() {
    setState(() {
      _teamsFuture = _playerService.getTeams();
    });
  }

  Future<void> _handleLogout() async {
    // Show confirmation dialog
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (shouldLogout == true && mounted) {
      try {
        final authService = AuthService();
        await authService.signOut();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Logged out successfully'),
              backgroundColor: Colors.green,
            ),
          );
          
          // Navigate to login screen
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const LoginScreen()),
            (route) => false,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error logging out: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Your Team'),
        centerTitle: true,
        actions: [
          // Logout button
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _handleLogout,
            tooltip: 'Logout',
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _teamsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text('Error: ${snapshot.error}'),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _refreshTeams,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          final teams = snapshot.data ?? [];

          if (teams.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.sports, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text(
                    'No teams yet',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap the button below to create your first team!',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _refreshTeams(),
            child: ListView.builder(
              itemCount: teams.length,
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) {
                final team = teams[index];
                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blue[50],
                      child: const Icon(Icons.group, color: Colors.blue),
                    ),
                    title: Text(
                      team['team_name'] ?? 'Unnamed Team',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(team['sport'] ?? 'General'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => RosterScreen(
                            teamId: team['id'],
                            teamName: team['team_name'], // Pass team name
                            sport: team['sport'], // Pass sport
                          ),
                        ),
                      );
                      // Refresh if roster screen indicates changes
                      if (result == true) {
                        _refreshTeams();
                      }
                    },
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateTeamDialog,
        label: const Text('New Team'),
        icon: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showCreateTeamDialog() async {
    final nameController = TextEditingController();
    final sportController = TextEditingController(text: 'General');
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Team'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                textInputAction: TextInputAction.next, // Added
                onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(), // Added
                decoration: const InputDecoration(
                  labelText: 'Team Name',
                  hintText: 'e.g. Tigers',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a team name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: sportController,
                textInputAction: TextInputAction.done, // Added
                onFieldSubmitted: (_) { // Added - Submit on Enter
                  if (formKey.currentState!.validate()) {
                    Navigator.pop(context, true);
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Sport',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    // Create team after dialog closes to avoid navigation issues
    if (result == true && mounted) {
      try {
        await _playerService.createTeam(
          nameController.text.trim(),
          sportController.text.trim(),
        );
        _refreshTeams();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Team created successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating team: $e')),
          );
        }
      }
    }

    nameController.dispose();
    sportController.dispose();
  }
}