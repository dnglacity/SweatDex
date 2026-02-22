import 'package:flutter/material.dart';
import 'package:sweatdex/models/player.dart';
import '../services/player_service.dart';
import '../services/auth_service.dart';
import 'add_player_screen.dart';
import 'manage_coaches_screen.dart';
import 'saved_roster_screen.dart';
import 'login_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// roster_screen.dart
//
// Main per-team player management screen.
//
// CHANGES (Notes.txt):
//   1. Three-dot (⋮) Logout now executes a full AuthService.signOut() call
//      and navigates to LoginScreen — previously it only popped the stack
//      without signing out of Supabase.
//   2. Game Roster button in the AppBar now uses Icons.assignment (clipboard)
//      instead of Icons.sports_score, per Notes.txt "change the game roster
//      icon on the roster screen to a clipboard."
//   3. "Only show the icons on the top left." — the AppBar now has no text
//      labels on action buttons; only icon buttons appear.
//      The "Game Rosters" and "Bulk Actions" text labels have been removed;
//      they are now icon-only buttons with tooltips.
//   4. Blue and Gold theme colours are applied via the inherited ThemeData.
//
// BUG FIX (Bug 8): When a coach removes themselves, popUntil(isFirst) is used
//   so RosterScreen doesn't try to stream players for a team they left.
// ─────────────────────────────────────────────────────────────────────────────

class RosterScreen extends StatefulWidget {
  final String teamId;
  final String teamName;
  final String? sport;

  const RosterScreen({
    super.key,
    required this.teamId,
    required this.teamName,
    this.sport,
  });

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> {
  final _playerService = PlayerService();
  final _authService = AuthService();

  // ── Bulk-delete mode ──────────────────────────────────────────────────────
  bool _bulkDeleteMode = false;
  final Set<String> _selectedIds = {};

  // ── Status helpers ────────────────────────────────────────────────────────

  Future<void> _updatePlayerStatus(Player player, String newStatus) async {
    try {
      await _playerService.updatePlayerStatus(player.id, newStatus);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${player.name} marked as $newStatus'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error updating status: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showStatusMenu(Player player) async {
    final newStatus = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${player.name} — Status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _statusOption('present', 'Present', Icons.check_circle, Colors.green),
            _statusOption('absent', 'Absent', Icons.cancel, Colors.red),
            _statusOption('late', 'Late', Icons.access_time, Colors.orange),
            _statusOption('excused', 'Excused', Icons.event_busy,
                Theme.of(context).colorScheme.primary),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (newStatus != null && mounted) {
      await _updatePlayerStatus(player, newStatus);
    }
  }

  Widget _statusOption(
      String status, String label, IconData icon, Color color) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      onTap: () => Navigator.pop(context, status),
    );
  }

  // ── Bulk Actions ──────────────────────────────────────────────────────────

  Future<void> _showBulkActions() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bulk Actions'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('Mark All Present'),
              onTap: () => Navigator.pop(ctx, 'present'),
            ),
            ListTile(
              leading: const Icon(Icons.cancel, color: Colors.red),
              title: const Text('Mark All Absent'),
              onTap: () => Navigator.pop(ctx, 'absent'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep, color: Colors.red),
              title: const Text('Bulk Delete',
                  style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'bulkDelete'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (action == null || !mounted) return;

    if (action == 'bulkDelete') {
      setState(() {
        _bulkDeleteMode = true;
        _selectedIds.clear();
      });
    } else {
      try {
        await _playerService.bulkUpdateStatus(widget.teamId, action);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('All players marked as $action')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _confirmBulkDelete() async {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No players selected')));
      return;
    }

    bool acknowledged = false;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Delete Players'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Permanently delete ${_selectedIds.length} player(s)? '
                'This cannot be undone.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: acknowledged,
                    activeColor: Colors.red,
                    onChanged: (v) => setLocal(() => acknowledged = v ?? false),
                  ),
                  const Expanded(
                    child: Text(
                      'I understand this is irreversible.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: acknowledged ? () => Navigator.pop(ctx, true) : null,
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );

    if (confirm == true && mounted) {
      try {
        await _playerService.bulkDeletePlayers(_selectedIds.toList());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_selectedIds.length} player(s) deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted) setState(() { _bulkDeleteMode = false; _selectedIds.clear(); });
      }
    }
  }

  // ── Three-dot overflow menu ───────────────────────────────────────────────

  void _showOverflowMenu() async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width,
        kToolbarHeight + MediaQuery.of(context).padding.top,
        0,
        0,
      ),
      items: const [
        PopupMenuItem(
          value: 'teamSettings',
          child: Row(children: [
            Icon(Icons.settings, size: 20),
            SizedBox(width: 12),
            Text('Team Settings'),
          ]),
        ),
        PopupMenuItem(
          value: 'coachSettings',
          child: Row(children: [
            Icon(Icons.manage_accounts, size: 20),
            SizedBox(width: 12),
            Text('Coach Settings'),
          ]),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'deleteRoster',
          child: Row(children: [
            Icon(Icons.delete_forever, color: Colors.red, size: 20),
            SizedBox(width: 12),
            Text('Delete Roster', style: TextStyle(color: Colors.red)),
          ]),
        ),
        PopupMenuDivider(),
        // CHANGE (Notes.txt): Logout now executes full signOut.
        PopupMenuItem(
          value: 'logout',
          child: Row(children: [
            Icon(Icons.logout, size: 20),
            SizedBox(width: 12),
            Text('Log Out'),
          ]),
        ),
      ],
    );

    if (action == null || !mounted) return;

    switch (action) {
      case 'teamSettings':
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Team Settings — coming soon')),
        );
        break;
      case 'coachSettings':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ManageCoachesScreen(
              teamId: widget.teamId,
              teamName: widget.teamName,
            ),
          ),
        );
        break;
      case 'deleteRoster':
        await _confirmDeleteRoster();
        break;
      case 'logout':
        // CHANGE (Notes.txt): Full signOut — not just a stack pop.
        await _performLogout();
        break;
    }
  }

  /// Signs the user out and navigates to LoginScreen, clearing the stack.
  Future<void> _performLogout() async {
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
      // Supabase signOut — invalidates the access token on the server.
      await _authService.signOut();
      if (mounted) {
        // Remove all routes so the user cannot go "back" to the roster.
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

  Future<void> _confirmDeleteRoster() async {
    bool acknowledged = false;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Delete Roster'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Permanently delete ALL players from "${widget.teamName}"? '
                'This cannot be undone.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: acknowledged,
                    activeColor: Colors.red,
                    onChanged: (v) => setLocal(() => acknowledged = v ?? false),
                  ),
                  const Expanded(
                    child: Text(
                      'I understand all players will be deleted.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: acknowledged ? () => Navigator.pop(ctx, true) : null,
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete All'),
            ),
          ],
        ),
      ),
    );

    if (confirm == true && mounted) {
      try {
        final players = await _playerService.getPlayers(widget.teamId);
        await _playerService.bulkDeletePlayers(
            players.map((p) => p.id).toList());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('All players deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
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
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.teamName} Roster',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (widget.sport != null && widget.sport!.isNotEmpty)
              Text(
                widget.sport!,
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
        // CHANGE (Notes.txt): "Only show the icons" — no text labels on actions.
        actions: [
          // CHANGE (Notes.txt): Game roster icon is now a clipboard (assignment).
          IconButton(
            icon: const Icon(Icons.assignment),
            tooltip: 'Game Rosters',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SavedRosterScreen(
                  teamId: widget.teamId,
                  teamName: widget.teamName,
                ),
              ),
            ),
          ),

          // Bulk Actions / Cancel bulk mode — icon only.
          _bulkDeleteMode
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel bulk delete',
                  onPressed: () => setState(() {
                    _bulkDeleteMode = false;
                    _selectedIds.clear();
                  }),
                )
              : IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: 'Bulk Actions',
                  onPressed: _showBulkActions,
                ),

          // Three-dot overflow.
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More options',
            onPressed: _showOverflowMenu,
          ),
        ],
      ),

      // ── Player list ───────────────────────────────────────────────────────
      body: StreamBuilder<List<Player>>(
        stream: _playerService.getPlayerStream(widget.teamId),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text('Error: ${snapshot.error}'),
                  ElevatedButton(
                    onPressed: () => setState(() {}),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final players = snapshot.data ?? [];

          if (players.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.people_outline,
                      size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text('No players yet',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('Tap + to add your first player!',
                      style: TextStyle(color: Colors.grey[600])),
                ],
              ),
            );
          }

          final present = players.where((p) => p.status == 'present').length;
          final absent = players.where((p) => p.status == 'absent').length;
          final late = players.where((p) => p.status == 'late').length;
          final excused = players.where((p) => p.status == 'excused').length;

          return Column(
            children: [
              // ── Summary card ──────────────────────────────────────────────
              Card(
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _summaryItem('Present', present, Colors.green),
                      _summaryItem('Absent', absent, Colors.red),
                      _summaryItem('Late', late, Colors.orange),
                      _summaryItem(
                          'Excused', excused, colorScheme.primary),
                    ],
                  ),
                ),
              ),

              // ── Bulk-delete info bar ──────────────────────────────────────
              if (_bulkDeleteMode)
                Container(
                  color: Colors.red[50],
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_selectedIds.length} of ${players.length} selected',
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          if (_selectedIds.length == players.length) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds
                                .addAll(players.map((p) => p.id));
                          }
                        }),
                        child: Text(
                          _selectedIds.length == players.length
                              ? 'Deselect All'
                              : 'Select All',
                        ),
                      ),
                    ],
                  ),
                ),

              // ── Player list ───────────────────────────────────────────────
              Expanded(
                child: ListView.builder(
                  itemCount: players.length,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemBuilder: (ctx, i) {
                    final player = players[i];
                    final isChecked = _selectedIds.contains(player.id);

                    // Bulk delete mode — checkboxes.
                    if (_bulkDeleteMode) {
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: _playerAvatar(player, colorScheme),
                          title: Text(player.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: _buildSubtitle(player),
                          trailing: Checkbox(
                            value: isChecked,
                            activeColor: Colors.red,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selectedIds.add(player.id);
                              } else {
                                _selectedIds.remove(player.id);
                              }
                            }),
                          ),
                          onTap: () => setState(() {
                            if (isChecked) {
                              _selectedIds.remove(player.id);
                            } else {
                              _selectedIds.add(player.id);
                            }
                          }),
                        ),
                      );
                    }

                    // Normal player tile with swipe-to-delete.
                    return Dismissible(
                      key: Key(player.id),
                      direction: DismissDirection.endToStart,
                      confirmDismiss: (_) async => showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Delete Player'),
                          content: Text(
                              'Remove ${player.name} from the roster?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      ),
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 20),
                        child: const Icon(Icons.delete,
                            color: Colors.white, size: 32),
                      ),
                      onDismissed: (_) async {
                        try {
                          await _playerService.deletePlayer(player.id);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      '${player.name} removed')),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Error removing: $e'),
                                  backgroundColor: Colors.red),
                            );
                          }
                        }
                      },
                      child: Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: _playerAvatar(player, colorScheme),
                          title: Text(player.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: _buildSubtitle(player),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Quick present/absent toggle.
                              IconButton(
                                icon: Icon(
                                  player.status == 'present'
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  color: player.status == 'present'
                                      ? Colors.green
                                      : Colors.grey,
                                  size: 28,
                                ),
                                onPressed: () async {
                                  final ns = player.status == 'present'
                                      ? 'absent'
                                      : 'present';
                                  await _updatePlayerStatus(player, ns);
                                },
                                tooltip: player.status == 'present'
                                    ? 'Mark Absent'
                                    : 'Mark Present',
                              ),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                onSelected: (v) async {
                                  if (v == 'status') {
                                    await _showStatusMenu(player);
                                  } else if (v == 'edit') {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => AddPlayerScreen(
                                          teamId: widget.teamId,
                                          playerToEdit: player,
                                        ),
                                      ),
                                    );
                                    if (mounted) setState(() {});
                                  } else if (v == 'delete') {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title:
                                            const Text('Delete Player'),
                                        content: Text(
                                            'Remove ${player.name}?'),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: const Text('Cancel'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            style: FilledButton.styleFrom(
                                                backgroundColor:
                                                    Colors.red),
                                            child: const Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok == true && mounted) {
                                      await _playerService
                                          .deletePlayer(player.id);
                                    }
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'status',
                                    child: Row(children: [
                                      Icon(Icons.event_available, size: 20),
                                      SizedBox(width: 12),
                                      Text('Change Status'),
                                    ]),
                                  ),
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Row(children: [
                                      Icon(Icons.edit, size: 20),
                                      SizedBox(width: 12),
                                      Text('Edit Player'),
                                    ]),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Row(children: [
                                      Icon(Icons.delete,
                                          color: Colors.red, size: 20),
                                      SizedBox(width: 12),
                                      Text('Delete',
                                          style: TextStyle(
                                              color: Colors.red)),
                                    ]),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: () => _showPlayerDetails(player),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),

      // ── FAB ──────────────────────────────────────────────────────────────
      floatingActionButton: _bulkDeleteMode
          ? FloatingActionButton.extended(
              onPressed: _confirmBulkDelete,
              backgroundColor: Colors.red,
              icon: const Icon(Icons.delete),
              label: Text(
                _selectedIds.isEmpty
                    ? 'Delete'
                    : 'Delete (${_selectedIds.length})',
              ),
            )
          : FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        AddPlayerScreen(teamId: widget.teamId),
                  ),
                );
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.person_add),
              label: const Text('Add Player'),
            ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _playerAvatar(Player player, ColorScheme cs) {
    return Stack(
      children: [
        CircleAvatar(
          backgroundColor: cs.primaryContainer,
          child: Text(
            player.displayJersey,
            style: TextStyle(
                fontWeight: FontWeight.bold, color: cs.onPrimaryContainer),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: player.statusColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _summaryItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(count.toString(),
            style: TextStyle(
                fontSize: 24, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }

  Widget _buildSubtitle(Player player) {
    final parts = <String>[];
    if (player.nickname != null && player.nickname!.isNotEmpty) {
      parts.add('"${player.nickname}"');
    }
    if (player.studentId != null && player.studentId!.isNotEmpty) {
      parts.add('ID: ${player.studentId}');
    }
    if (parts.isEmpty) {
      return Text(
        player.studentEmail ?? 'No additional info',
        style: TextStyle(color: Colors.grey[600]),
      );
    }
    return Text(parts.join(' • '),
        style: TextStyle(color: Colors.grey[600]));
  }

  void _showPlayerDetails(Player player) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(player.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (player.jerseyNumber != null)
              _detailRow('Jersey', player.jerseyNumber!),
            if (player.nickname != null && player.nickname!.isNotEmpty)
              _detailRow('Nickname', player.nickname!),
            if (player.studentId != null && player.studentId!.isNotEmpty)
              _detailRow('Student ID', player.studentId!),
            if (player.studentEmail != null &&
                player.studentEmail!.isNotEmpty)
              _detailRow('Email', player.studentEmail!),
            _detailRow('Status', player.statusLabel),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _showStatusMenu(player);
            },
            icon: Icon(player.statusIcon, size: 16),
            label: const Text('Change Status'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AddPlayerScreen(
                    teamId: widget.teamId,
                    playerToEdit: player,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.edit),
            label: const Text('Edit'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 100,
              child: Text('$label:',
                  style: const TextStyle(fontWeight: FontWeight.bold))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}