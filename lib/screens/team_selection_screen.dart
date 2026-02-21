import 'package:flutter/material.dart';
import '../services/player_service.dart';
import 'roster_screen.dart';
import 'login_screen.dart';
import '../services/auth_service.dart';

/// TeamSelectionScreen — shows all teams the authenticated coach belongs to.
/// Provides create, edit, delete, and open-roster actions per team.
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

  /// Re-fetches the team list and triggers a rebuild.
  void _refreshTeams() {
    setState(() {
      _teamsFuture = _playerService.getTeams();
    });
  }

  /// Shows a confirmation dialog and signs the user out if confirmed.
  Future<void> _handleLogout() async {
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
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
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
          // Remove all routes and go to LoginScreen.
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

  /// Opens a dialog pre-filled with the team's current name and sport.
  /// BUG FIX: Renamed the local guard variable from `_submitted` (which
  /// incorrectly used the private-member underscore convention) to `submitted`.
  Future<void> _showEditTeamDialog(Map<String, dynamic> team) async {
    final nameController = TextEditingController(text: team['team_name']);
    final sportController =
        TextEditingController(text: team['sport'] ?? 'General');
    final formKey = GlobalKey<FormState>();

    // FIX (Bug 1): Use `submitted` (no leading underscore) for a local variable.
    // The underscore prefix is a Dart convention for private class members,
    // not local variables, and causes lint warnings here.
    bool submitted = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Team'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
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
                textInputAction: TextInputAction.done,
                // Guard with `submitted` to prevent double-pop on Enter key.
                onFieldSubmitted: (_) {
                  if (!submitted && formKey.currentState!.validate()) {
                    submitted = true;
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
            onPressed: () {
              if (!submitted && formKey.currentState!.validate()) {
                submitted = true;
                Navigator.pop(context, true);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      try {
        await _playerService.updateTeam(
          team['id'],
          nameController.text.trim(),
          sportController.text.trim(),
        );
        _refreshTeams();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Team updated successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error updating team: $e')),
          );
        }
      }
    }

    nameController.dispose();
    sportController.dispose();
  }

  /// Confirms and deletes a team along with all its cascaded data.
  Future<void> _showDeleteTeamDialog(Map<String, dynamic> team) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Team'),
        content: Text(
          'Are you sure you want to delete "${team['team_name']}"?\n\n'
          'This will also delete all players on this team. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      try {
        await _playerService.deleteTeam(team['id']);
        _refreshTeams();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${team['team_name']} deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting team: $e'),
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
          // Show loading spinner while awaiting data.
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

          // Empty state — prompt the coach to create their first team.
          if (teams.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.sports, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text(
                    'No teams yet',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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

          // Pull-to-refresh wraps the list.
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
                    // Gold avatar for team owner, blue for regular coach.
                    leading: CircleAvatar(
                      backgroundColor: team['is_owner'] == true
                          ? Colors.amber[100]
                          : Colors.blue[50],
                      child: Icon(
                        team['is_owner'] == true
                            ? Icons.shield
                            : Icons.group,
                        color: team['is_owner'] == true
                            ? Colors.amber[700]
                            : Colors.blue,
                      ),
                    ),
                    title: Row(
                      children: [
                        Text(
                          team['team_name'] ?? 'Unnamed Team',
                          style:
                              const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (team['is_owner'] == true) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.amber[100],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              'OWNER',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.amber[900],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(team['sport'] ?? 'General'),
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      onSelected: (value) async {
                        if (value == 'open') {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => RosterScreen(
                                teamId: team['id'],
                                teamName: team['team_name'],
                                sport: team['sport'],
                              ),
                            ),
                          );
                          // Refresh after returning from the roster.
                          _refreshTeams();
                        } else if (value == 'edit') {
                          await _showEditTeamDialog(team);
                        } else if (value == 'delete') {
                          await _showDeleteTeamDialog(team);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'open',
                          child: Row(
                            children: [
                              Icon(Icons.open_in_new, size: 20),
                              SizedBox(width: 12),
                              Text('Open Roster'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 20),
                              SizedBox(width: 12),
                              Text('Edit Team'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete, color: Colors.red, size: 20),
                              SizedBox(width: 12),
                              Text('Delete Team',
                                  style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    // Tapping the card also opens the roster.
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => RosterScreen(
                            teamId: team['id'],
                            teamName: team['team_name'],
                            sport: team['sport'],
                          ),
                        ),
                      );
                      _refreshTeams();
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

  /// Opens a form dialog for creating a new team.
  /// BUG FIX (Bug 1): Local submission guard renamed from `_submitted` → `submitted`.
  Future<void> _showCreateTeamDialog() async {
    final nameController = TextEditingController();
    final sportController = TextEditingController(text: 'General');
    final formKey = GlobalKey<FormState>();

    // FIX (Bug 1): Plain local variable — no underscore prefix.
    bool submitted = false;

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
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
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
                textInputAction: TextInputAction.done,
                // Guard prevents double-pop when the user presses Enter.
                onFieldSubmitted: (_) {
                  if (!submitted && formKey.currentState!.validate()) {
                    submitted = true;
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
            onPressed: () {
              if (!submitted && formKey.currentState!.validate()) {
                submitted = true;
                Navigator.pop(context, true);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

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