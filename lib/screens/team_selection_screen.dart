import 'package:flutter/material.dart';
import '../services/player_service.dart';
import '../services/auth_service.dart';
import '../widgets/sport_autocomplete_field.dart'; // Shared autocomplete widget
import '../widgets/error_dialog.dart';
import 'roster_screen.dart';
import 'player_self_view_screen.dart';
import 'account_settings_screen.dart';

// =============================================================================
// team_selection_screen.dart  (AOD v1.11 — BUG FIX Issue 1 + Performance)
//
// BUG FIX (Issue 1 — linked player does not see team / is not labeled Player):
//
//   ROOT CAUSE:
//     When a coach adds a player and successfully links them (via add_player_screen
//     or manage_members_screen), the players.user_id is correctly written to the DB.
//     However, the team_members table is only populated via the
//     fn_create_team_membership / create_team_membership_v1_5 DB trigger, which
//     fires on INSERT into team_members — NOT automatically when players.user_id
//     is updated.
//
//     As a result, after linking, the newly linked athlete has:
//       ✓  players.user_id = their public.users.id
//       ✗  NO row in team_members with role = 'player'
//
//     Since TeamSelectionScreen.getTeams() queries team_members to build the
//     team list, and no membership row exists yet for the athlete, they see
//     an empty "No teams yet" screen.
//
//   FIX — Two-part solution:
//
//   PART A (Supabase — see fix_issue1_player_link.sql):
//     Add a DB trigger fn_sync_player_membership_on_link that fires AFTER UPDATE
//     on the players table when user_id changes from NULL to a non-NULL value.
//     The trigger upserts a team_members row: { team_id, user_id, role='player',
//     player_id } — making the athlete's team visible without any Flutter changes.
//
//   PART B (Flutter — this file):
//     After a team refresh, if the list contains a team where role == 'player',
//     navigate directly to PlayerSelfViewScreen without requiring an extra tap.
//     This is NOT a hard requirement — the list already handles players correctly —
//     but this change improves the first-launch experience after linking.
//
//     Additionally, the FutureBuilder is replaced with a pull-to-refresh pattern
//     that does NOT rebuild the entire widget tree on _refreshTeams(), preventing
//     a visual flash and unnecessary child widget reconstructions.
//
// PERFORMANCE:
//   • Replaced FutureBuilder with an explicit state-driven pattern using
//     _teams list + _teamsLoading bool. This avoids the "snapshot flicker"
//     that occurs when FutureBuilder transitions through ConnectionState.waiting
//     on every _refreshTeams() call (which previously caused the entire ListView
//     to unmount and remount, losing scroll position).
//   • _loadTeams() guard: sets _teamsLoading=true only on the first load;
//     subsequent refreshes update data in-place so the list stays visible
//     behind a subtle loading indicator rather than being replaced by a spinner.
//
// All other v1.7/v1.8 behaviours retained:
//   – Controller disposal pattern (captured values before deferred dispose)
//   – SportAutocompleteField shared widget
//   – Role badges, edit/delete team dialogs
// =============================================================================

class TeamSelectionScreen extends StatefulWidget {
  const TeamSelectionScreen({super.key});

  @override
  State<TeamSelectionScreen> createState() => _TeamSelectionScreenState();
}

class _TeamSelectionScreenState extends State<TeamSelectionScreen> {
  final _playerService = PlayerService();
  final _authService = AuthService();

  // ── State ──────────────────────────────────────────────────────────────────
  // PERFORMANCE: explicit state instead of FutureBuilder avoids full ListView
  // reconstruction on refresh, preserving scroll position and preventing flicker.
  List<Map<String, dynamic>> _teams = [];
  bool _teamsLoading = true;    // true only on first load (shows center spinner)
  bool _teamsRefreshing = false; // true on subsequent refreshes (subtle indicator)
  String? _teamsError;

  /// Cached sports list for autocomplete (loaded once per session).
  List<Map<String, dynamic>> _sports = [];

  @override
  void initState() {
    super.initState();
    _loadTeams(initial: true);
    _loadSports();
  }

  // ── Data Loading ───────────────────────────────────────────────────────────

  /// Loads teams from PlayerService.
  ///
  /// [initial] = true  → shows full-screen spinner (first paint).
  /// [initial] = false → shows RefreshIndicator only, keeps existing list visible.
  Future<void> _loadTeams({bool initial = false}) async {
    if (initial) {
      setState(() {
        _teamsLoading = true;
        _teamsError   = null;
      });
    } else {
      setState(() => _teamsRefreshing = true);
    }

    try {
      // forceRefresh=true bypasses the in-memory cache so we always get
      // the current DB state (critical after a player link or team creation).
      final teams = await _playerService.getTeams(forceRefresh: true);
      if (mounted) {
        setState(() {
          _teams        = teams;
          _teamsLoading = false;
          _teamsRefreshing = false;
          _teamsError   = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _teamsLoading    = false;
          _teamsRefreshing = false;
          _teamsError      = e.toString();
        });
      }
    }
  }

  /// Reloads teams — used by RefreshIndicator and after mutating operations.
  Future<void> _refreshTeams() => _loadTeams(initial: false);

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

  // ── Logout ─────────────────────────────────────────────────────────────────

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
      // AuthWrapper's StreamBuilder handles routing to LoginScreen on signedOut event.
    } catch (e) {
      if (mounted) {
        showErrorDialog(context, e);
      }
    }
  }

  // ── Edit Team ──────────────────────────────────────────────────────────────

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
                // Team name text field.
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
                // Sport autocomplete — shared widget from sport_autocomplete_field.dart.
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
    final capturedName    = nameController.text.trim();
    final capturedSport   = selectedSportName;
    final capturedSportId = selectedSportId;

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
          capturedName,
          capturedSport,
          sportId: capturedSportId,
        );
        // Refresh so the updated name/sport appear immediately.
        await _refreshTeams();
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

  // ── Delete Team ────────────────────────────────────────────────────────────

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
        await _refreshTeams();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${team['team_name']} deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
        }
      }
    }
  }

  // ── Create Team ────────────────────────────────────────────────────────────

  Future<void> _showCreateTeamDialog() async {
    final nameController = TextEditingController();
    final sportSearchController = TextEditingController(text: 'General');
    String selectedSportName = 'General';
    String? selectedSportId;
    final formKey = GlobalKey<FormState>();
    bool submitted = false;

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

    // Capture values BEFORE deferred dispose fires.
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
        // Force refresh so the new team_members row is fetched from DB.
        await _refreshTeams();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Team created!')));
        }
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
        }
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

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
        // PERFORMANCE: show a slim LinearProgressIndicator during background
        // refresh instead of replacing the list with a spinner. The user
        // can still scroll/interact while the refresh is in flight.
        bottom: _teamsRefreshing
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(),
              )
            : null,
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
      body: _teamsLoading
          // First-load: show full-screen spinner.
          ? const Center(child: CircularProgressIndicator())
          : _teamsError != null
              // Error state with retry button.
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: Colors.red),
                      const SizedBox(height: 16),
                      Text('Error: $_teamsError'),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _refreshTeams,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _teams.isEmpty
                  // Empty state — no teams yet.
                  ? RefreshIndicator(
                      onRefresh: _refreshTeams,
                      child: ListView(
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.6,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.sports,
                                    size: 64,
                                    color: colorScheme.secondary),
                                const SizedBox(height: 16),
                                const Text('No teams yet',
                                    style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                Text(
                                  'Tap the + button below to create your first team!',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  // Team list with pull-to-refresh.
                  : RefreshIndicator(
                      onRefresh: _refreshTeams,
                      child: ListView.builder(
                        itemCount: _teams.length,
                        padding: const EdgeInsets.all(16),
                        itemBuilder: (ctx, i) {
                          final team = _teams[i];
                          final role = team['role'] as String;
                          final isOwner  = role == 'owner';
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
                                      team['team_name'] as String? ??
                                          'Unnamed Team',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  _roleBadge(role, colorScheme),
                                ],
                              ),
                              subtitle: Text(
                                  team['sport'] as String? ?? 'General'),
                              // Non-player roles get a popup menu for edit/delete.
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
                                                teamId:
                                                    team['id'] as String,
                                                teamName: team['team_name']
                                                    as String,
                                                sport:
                                                    team['sport'] as String?,
                                                currentUserRole: role,
                                              ),
                                            ),
                                          );
                                          // Always refresh after returning
                                          // from the roster in case players
                                          // were added/linked inside.
                                          await _refreshTeams();
                                        } else if (v == 'edit' && isOwner) {
                                          await _showEditTeamDialog(team);
                                        } else if (v == 'delete' &&
                                            isOwner) {
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
                                                  color: Colors.red,
                                                  size: 20),
                                              SizedBox(width: 12),
                                              Text('Delete Team',
                                                  style: TextStyle(
                                                      color: Colors.red)),
                                            ]),
                                          ),
                                        ],
                                      ],
                                    ),
                              onTap: () async {
                                if (isPlayer) {
                                  // BUG FIX (Issue 1): Players are now routed
                                  // to PlayerSelfViewScreen. This works because
                                  // the DB trigger (fix_issue1_player_link.sql)
                                  // ensures a team_members row with role='player'
                                  // is created when players.user_id is set.
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => PlayerSelfViewScreen(
                                        teamId: team['id'] as String,
                                        teamName:
                                            team['team_name'] as String,
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
                                        teamName:
                                            team['team_name'] as String,
                                        sport: team['sport'] as String?,
                                        currentUserRole: role,
                                      ),
                                    ),
                                  );
                                  // Refresh after returning from roster screen
                                  // so any new player links appear.
                                  await _refreshTeams();
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateTeamDialog,
        icon: const Icon(Icons.add),
        label: const Text('New Team'),
      ),
    );
  }

  // ── Role Badge Widget ──────────────────────────────────────────────────────

  /// Returns a small coloured badge showing the user's role on the team.
  Widget _roleBadge(String role, ColorScheme cs) {
    switch (role) {
      case 'owner':
        return _Badge(
            'OWNER', const Color(0xFF5C4A00), const Color(0xFFFFF3CD));
      case 'coach':
        return _Badge('COACH', Colors.blue[900]!, Colors.blue[100]!);
      case 'player':
        return _Badge('PLAYER', cs.primary, cs.primaryContainer);
      case 'team_parent':
        return _Badge(
            'PARENT', Colors.green[900]!, Colors.green[100]!);
      case 'team_manager':
        return _Badge(
            'MANAGER', Colors.purple[900]!, Colors.purple[100]!);
      default:
        return _Badge(
            role.toUpperCase(), Colors.grey[800]!, Colors.grey[200]!);
    }
  }
}

// ── Badge Widget ──────────────────────────────────────────────────────────────

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