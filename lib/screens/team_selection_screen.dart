import 'package:flutter/material.dart';
import '../services/player_service.dart';
import '../services/auth_service.dart';
import '../widgets/sport_autocomplete_field.dart'; // Shared autocomplete widget
import 'roster_screen.dart';
import 'login_screen.dart';
import 'player_self_view_screen.dart';
import 'account_settings_screen.dart';

// =============================================================================
// team_selection_screen.dart  (AOD v1.7 — updated, BUG FIX v1.8-patch)
//
// BUG FIX (AI_REVIEW — _showEditTeamDialog stale controller read):
//   The original _showEditTeamDialog() deferred controller disposal via
//   addPostFrameCallback, but then read nameController.text AFTER the deferred
//   dispose call was registered. On the same frame that the dialog closes,
//   the deferred dispose fires and the subsequent
//   `nameController.text.trim()` read inside the `if (result == true)` block
//   could access a disposed controller — especially on fast devices where the
//   animation completes in one frame.
//
//   Fix: capture `capturedName` and `capturedSport` from the controller/local
//   variable IMMEDIATELY after showDialog() returns (while the controller is
//   still alive), then pass the captured strings into updateTeam() and
//   dispose the controllers on the next frame. This is identical to the
//   pattern already applied in roster_screen.dart._showEditTeamInline().
//
// BUG FIX (Notes.txt — Sport field typing):
//   Replaced the local _SportAutocompleteField StatelessWidget with the
//   shared SportAutocompleteField StatefulWidget from
//   lib/widgets/sport_autocomplete_field.dart.
//
// All other v1.7 behaviours retained.
// =============================================================================

class TeamSelectionScreen extends StatefulWidget {
  const TeamSelectionScreen({super.key});

  @override
  State<TeamSelectionScreen> createState() => _TeamSelectionScreenState();
}

class _TeamSelectionScreenState extends State<TeamSelectionScreen> {
  final _playerService = PlayerService();
  final _authService = AuthService();

  late Future<List<Map<String, dynamic>>> _teamsFuture;

  /// Cached sports list for autocomplete (loaded once per session).
  List<Map<String, dynamic>> _sports = [];

  @override
  void initState() {
    super.initState();
    _refreshTeams();
    _loadSports();
  }

  /// Triggers a fresh fetch of the user's teams.
  void _refreshTeams() {
    setState(() {
      _teamsFuture = _playerService.getTeams();
    });
  }

  /// Loads the sports list from the DB for autocomplete suggestions.
  /// Non-fatal — manual text entry still works if this call fails.
  Future<void> _loadSports() async {
    try {
      final sports = await _playerService.getSports();
      if (mounted) setState(() => _sports = sports);
    } catch (_) {
      // Fallback: getSports() returns a hardcoded 'General' entry on error.
    }
  }

  // ── Logout ────────────────────────────────────────────────────────────────

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      // Clear in-memory and disk caches before signing out so the next
      // account on this device gets a fresh state.
      _playerService.clearCache();
      await _authService.signOut();
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error logging out: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  // ── Edit team ─────────────────────────────────────────────────────────────

  Future<void> _showEditTeamDialog(Map<String, dynamic> team) async {
    final nameController = TextEditingController(text: team['team_name']);
    String selectedSportName = team['sport'] as String? ?? 'General';
    String? selectedSportId = team['sport_id'] as String?;
    final sportSearchController =
        TextEditingController(text: selectedSportName);
    final formKey = GlobalKey<FormState>();
    bool submitted = false; // Guards against double-submit on fast taps.

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Edit Team'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Team Name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Please enter a team name'
                      : null,
                ),
                const SizedBox(height: 16),
                // Uses the fixed StatefulWidget — prevents typed text being
                // reset on every rebuild (see sport_autocomplete_field.dart).
                SportAutocompleteField(
                  controller: sportSearchController,
                  sports: _sports,
                  initialSportId: selectedSportId,
                  onSelected: (name, id) {
                    setLocal(() {
                      selectedSportName = name;
                      selectedSportId = id;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (!submitted && formKey.currentState!.validate()) {
                  submitted = true;
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    // BUG FIX: Capture controller values BEFORE the deferred dispose fires.
    // Reading nameController.text after dispose() throws an assertion error.
    // This mirrors the pattern in roster_screen.dart._showEditTeamInline().
    final capturedName  = nameController.text.trim();
    final capturedSport = selectedSportName; // local variable; always safe
    final capturedSportId = selectedSportId; // capture nullable String too

    // Defer disposal so Flutter's dialog-close animation can fully detach
    // the TextFormField from the controller before it is destroyed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameController.dispose();
      sportSearchController.dispose();
    });

    if (result == true && mounted) {
      try {
        await _playerService.updateTeam(
          team['id'] as String,
          capturedName,       // use captured value — not nameController.text
          capturedSport,      // use captured value — not selectedSportName
          sportId: capturedSportId,
        );
        _refreshTeams();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Team updated!')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  // ── Delete team ────────────────────────────────────────────────────────────

  Future<void> _showDeleteTeamDialog(Map<String, dynamic> team) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Team'),
        content: Text(
          'Delete "${team['team_name']}"?\n\n'
          'All players will also be deleted. This cannot be undone.\n\n'
          'Note: All coaches must be removed before the team can be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      try {
        await _playerService.deleteTeam(team['id'] as String);
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
                content: Text(e.toString().replaceAll('Exception: ', '')),
                backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  // ── Create team dialog ─────────────────────────────────────────────────────

  Future<void> _showCreateTeamDialog() async {
    final nameController = TextEditingController();
    final sportSearchController = TextEditingController(text: 'General');
    String selectedSportName = 'General';
    String? selectedSportId;
    final formKey = GlobalKey<FormState>();
    bool submitted = false; // Prevents double-submit on fast taps.

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New Team'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => FocusScope.of(ctx).nextFocus(),
                  decoration: const InputDecoration(
                    labelText: 'Team Name',
                    hintText: 'e.g. Tigers',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Please enter a team name'
                      : null,
                ),
                const SizedBox(height: 16),
                // Uses the fixed StatefulWidget from sport_autocomplete_field.dart.
                SportAutocompleteField(
                  controller: sportSearchController,
                  sports: _sports,
                  onSelected: (name, id) {
                    setLocal(() {
                      selectedSportName = name;
                      selectedSportId = id;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (!submitted && formKey.currentState!.validate()) {
                  submitted = true;
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    // Capture values BEFORE deferred dispose — same safety pattern as above.
    final capturedName    = nameController.text.trim();
    final capturedSport   = selectedSportName;
    final capturedSportId = selectedSportId;

    // Deferred disposal to let the dialog animation complete.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameController.dispose();
      sportSearchController.dispose();
    });

    if (result == true && mounted) {
      try {
        await _playerService.createTeam(
          capturedName,
          capturedSport,
          sportId: capturedSportId,
        );
        _refreshTeams();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Team created!')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString().replaceAll('Exception: ', '')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Your Team'),
        leading: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Icon(Icons.sports, color: colorScheme.secondary, size: 28),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) async {
              if (v == 'accountSettings') {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AccountSettingsScreen()),
                );
              } else if (v == 'logout') {
                await _handleLogout();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'accountSettings',
                child: Row(children: [
                  Icon(Icons.manage_accounts, size: 20),
                  SizedBox(width: 12),
                  Text('Account Settings'),
                ]),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout, size: 20),
                  SizedBox(width: 12),
                  Text('Log Out'),
                ]),
              ),
            ],
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
                  const Icon(Icons.error_outline,
                      size: 48, color: Colors.red),
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
                  Icon(Icons.sports, size: 64, color: colorScheme.secondary),
                  const SizedBox(height: 16),
                  const Text('No teams yet',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Tap the + button below to create your first team!',
                      style: TextStyle(color: Colors.grey[600])),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => _refreshTeams(),
            child: ListView.builder(
              itemCount: teams.length,
              padding: const EdgeInsets.all(16),
              itemBuilder: (ctx, i) {
                final team = teams[i];
                final role = team['role'] as String;
                final isOwner = role == 'owner';
                final isPlayer = role == 'player';

                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isPlayer
                          ? colorScheme.primaryContainer
                          : isOwner
                              ? const Color(0xFFFFF3CD)
                              : colorScheme.primaryContainer,
                      child: Icon(
                        isPlayer
                            ? Icons.directions_run
                            : isOwner
                                ? Icons.shield
                                : Icons.group,
                        color: isPlayer
                            ? colorScheme.primary
                            : isOwner
                                ? const Color(0xFFF4C430)
                                : colorScheme.primary,
                      ),
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            team['team_name'] as String? ?? 'Unnamed Team',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _roleBadge(role, colorScheme),
                      ],
                    ),
                    subtitle:
                        Text(team['sport'] as String? ?? 'General'),
                    trailing: isPlayer
                        ? null
                        : PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (v) async {
                              if (v == 'open') {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => RosterScreen(
                                      teamId: team['id'] as String,
                                      teamName:
                                          team['team_name'] as String,
                                      sport: team['sport'] as String?,
                                      currentUserRole: role,
                                    ),
                                  ),
                                );
                                _refreshTeams();
                              } else if (v == 'edit' && isOwner) {
                                await _showEditTeamDialog(team);
                              } else if (v == 'delete' && isOwner) {
                                await _showDeleteTeamDialog(team);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'open',
                                child: Row(children: [
                                  Icon(Icons.open_in_new, size: 20),
                                  SizedBox(width: 12),
                                  Text('Open Roster'),
                                ]),
                              ),
                              if (isOwner) ...[
                                const PopupMenuItem(
                                  value: 'edit',
                                  child: Row(children: [
                                    Icon(Icons.edit, size: 20),
                                    SizedBox(width: 12),
                                    Text('Edit Team'),
                                  ]),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Row(children: [
                                    Icon(Icons.delete,
                                        color: Colors.red, size: 20),
                                    SizedBox(width: 12),
                                    Text('Delete Team',
                                        style:
                                            TextStyle(color: Colors.red)),
                                  ]),
                                ),
                              ],
                            ],
                          ),
                    onTap: () async {
                      if (isPlayer) {
                        // Players see read-only PlayerSelfViewScreen.
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PlayerSelfViewScreen(
                              teamId: team['id'] as String,
                              teamName: team['team_name'] as String,
                            ),
                          ),
                        );
                      } else {
                        // Coaches, owners, managers see the full roster.
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => RosterScreen(
                              teamId: team['id'] as String,
                              teamName: team['team_name'] as String,
                              sport: team['sport'] as String?,
                              currentUserRole: role,
                            ),
                          ),
                        );
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
        icon: const Icon(Icons.add),
        label: const Text('New Team'),
      ),
    );
  }

  // ── Role badge widget ──────────────────────────────────────────────────────

  /// Returns a small coloured badge showing the user's role on the team.
  Widget _roleBadge(String role, ColorScheme cs) {
    switch (role) {
      case 'owner':
        return _Badge('OWNER', const Color(0xFF5C4A00),
            const Color(0xFFFFF3CD));
      case 'coach':
        return _Badge('COACH', Colors.blue[900]!, Colors.blue[100]!);
      case 'player':
        return _Badge('PLAYER', cs.primary, cs.primaryContainer);
      case 'team_parent':
        return _Badge('PARENT', Colors.green[900]!, Colors.green[100]!);
      case 'team_manager':
        return _Badge('MANAGER', Colors.purple[900]!, Colors.purple[100]!);
      default:
        return _Badge(
            role.toUpperCase(), Colors.grey[800]!, Colors.grey[200]!);
    }
  }
}

// ── Badge widget ──────────────────────────────────────────────────────────────

/// Compact pill badge used to display a user's role on a team card.
class _Badge extends StatelessWidget {
  final String label;
  final Color textColor;
  final Color bgColor;

  const _Badge(this.label, this.textColor, this.bgColor);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: textColor,
        ),
      ),
    );
  }
}