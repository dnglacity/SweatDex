import 'package:flutter/material.dart';
import 'package:sweatdex/models/player.dart';
import '../services/player_service.dart';
import 'add_player_screen.dart';
import 'manage_coaches_screen.dart';
import 'saved_roster_screen.dart';

/// RosterScreen — the main per-team player management screen.
///
/// Features (Notes.txt):
///   • Three-dot (⋮) overflow menu with Logout and, once a team is loaded,
///     team settings, coach settings, and delete roster options.
///   • "Game Rosters" button that navigates to [SavedRosterScreen].
///   • "Bulk Actions" button next to the three-dot icon.
///   • Bulk delete mode: shows a checkbox on each player row; replaces the FAB
///     with a red Delete button; confirms with a warning dialog.
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

  // ── Bulk-delete mode state ────────────────────────────────────────────────
  bool _bulkDeleteMode = false; // True when checkboxes are visible.
  final Set<String> _selectedIds = {}; // IDs of checked players.

  // ── Status update helpers ─────────────────────────────────────────────────

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
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showStatusMenu(Player player) async {
    final newStatus = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${player.name} — Update Status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildStatusOption('present', 'Present', Icons.check_circle, Colors.green),
            _buildStatusOption('absent', 'Absent', Icons.cancel, Colors.red),
            _buildStatusOption('late', 'Late', Icons.access_time, Colors.orange),
            _buildStatusOption('excused', 'Excused', Icons.event_busy, Colors.blue),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (newStatus != null && mounted) {
      await _updatePlayerStatus(player, newStatus);
    }
  }

  Widget _buildStatusOption(
      String status, String label, IconData icon, Color color) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      onTap: () => Navigator.pop(context, status),
    );
  }

  // ── Bulk Actions dialog ───────────────────────────────────────────────────

  /// Shows the Bulk Actions menu. Adds a "Bulk Delete" option which activates
  /// checkbox mode instead of immediately deleting.
  Future<void> _showBulkActions() async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bulk Actions'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('Mark All Present'),
              onTap: () => Navigator.pop(context, 'present'),
            ),
            ListTile(
              leading: const Icon(Icons.cancel, color: Colors.red),
              title: const Text('Mark All Absent'),
              onTap: () => Navigator.pop(context, 'absent'),
            ),
            // Bulk delete — enters checkbox selection mode.
            ListTile(
              leading: const Icon(Icons.delete_sweep, color: Colors.red),
              title: const Text('Bulk Delete',
                  style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(context, 'bulkDelete'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (action == null || !mounted) return;

    if (action == 'bulkDelete') {
      // Enter checkbox-selection mode; the FAB becomes a red Delete button.
      setState(() {
        _bulkDeleteMode = true;
        _selectedIds.clear();
      });
    } else {
      // Mark all present or absent.
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

  // ── Bulk delete confirmation ──────────────────────────────────────────────

  Future<void> _confirmBulkDelete() async {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No players selected')),
      );
      return;
    }

    // Warning dialog with checkbox acknowledgement.
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
                'You are about to permanently delete '
                '${_selectedIds.length} player(s). This cannot be undone.',
              ),
              const SizedBox(height: 16),
              // Acknowledgement checkbox — must be checked before Delete enables.
              Row(
                children: [
                  Checkbox(
                    value: acknowledged,
                    activeColor: Colors.red,
                    onChanged: (v) =>
                        setLocal(() => acknowledged = v ?? false),
                  ),
                  const Expanded(
                    child: Text(
                      'I understand this action is irreversible.',
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
              // Delete button is disabled until the checkbox is ticked.
              onPressed: acknowledged
                  ? () => Navigator.pop(ctx, true)
                  : null,
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
            SnackBar(
                content: Text(
                    '${_selectedIds.length} player(s) deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Error deleting players: $e'),
                backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted) {
          setState(() {
            _bulkDeleteMode = false;
            _selectedIds.clear();
          });
        }
      }
    }
  }

  // ── Three-dot overflow menu ───────────────────────────────────────────────

  /// Builds the ⋮ popup menu. Items are always available once the screen loads.
  void _showOverflowMenu(BuildContext context) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width, // align to right
        kToolbarHeight + MediaQuery.of(context).padding.top,
        0,
        0,
      ),
      items: [
        const PopupMenuItem(
          value: 'teamSettings',
          child: Row(children: [
            Icon(Icons.settings, size: 20),
            SizedBox(width: 12),
            Text('Team Settings'),
          ]),
        ),
        const PopupMenuItem(
          value: 'coachSettings',
          child: Row(children: [
            Icon(Icons.manage_accounts, size: 20),
            SizedBox(width: 12),
            Text('Coach Settings'),
          ]),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'deleteRoster',
          child: Row(children: [
            Icon(Icons.delete_forever, color: Colors.red, size: 20),
            SizedBox(width: 12),
            Text('Delete Roster',
                style: TextStyle(color: Colors.red)),
          ]),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
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
        // TODO: Navigate to a team-settings screen when built.
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
        // Pop back to the top of the navigator stack (TeamSelectionScreen
        // manages logout state via the AuthWrapper stream).
        Navigator.of(context).popUntil((route) => route.isFirst);
        break;
    }
  }

  /// Confirms and then clears all players from the team roster.
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
                'This will permanently delete ALL players from '
                '"${widget.teamName}". This action cannot be undone.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: acknowledged,
                    activeColor: Colors.red,
                    onChanged: (v) =>
                        setLocal(() => acknowledged = v ?? false),
                  ),
                  const Expanded(
                    child: Text(
                      'I understand this will delete all players.',
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
              onPressed: acknowledged
                  ? () => Navigator.pop(ctx, true)
                  : null,
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete All'),
            ),
          ],
        ),
      ),
    );

    if (confirm == true && mounted) {
      try {
        // Fetch all player IDs for the team then bulk-delete.
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
            SnackBar(
                content: Text('Error: $e'),
                backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
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
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.normal),
              ),
          ],
        ),
        centerTitle: true,
        actions: [
          // ── Game Rosters button ──────────────────────────────────────────
          TextButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SavedRosterScreen(
                    teamId: widget.teamId,
                    teamName: widget.teamName,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.sports_score, size: 18),
            label: const Text('Game Rosters',
                style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),

          // ── Bulk Actions button ──────────────────────────────────────────
          // When in bulk-delete mode this becomes a cancel button.
          _bulkDeleteMode
              ? TextButton(
                  onPressed: () => setState(() {
                    _bulkDeleteMode = false;
                    _selectedIds.clear();
                  }),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.orange)),
                )
              : TextButton.icon(
                  onPressed: _showBulkActions,
                  icon: const Icon(Icons.checklist, size: 18),
                  label: const Text('Bulk Actions',
                      style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),

          // ── Three-dot overflow menu ──────────────────────────────────────
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More options',
            onPressed: () => _showOverflowMenu(context),
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
                  const SizedBox(height: 16),
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
                  Text(
                    'Tap the + button to add your first player!',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ],
              ),
            );
          }

          // Attendance summary counts.
          final present =
              players.where((p) => p.status == 'present').length;
          final absent =
              players.where((p) => p.status == 'absent').length;
          final late = players.where((p) => p.status == 'late').length;
          final excused =
              players.where((p) => p.status == 'excused').length;

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
                      _buildSummaryItem('Present', present, Colors.green),
                      _buildSummaryItem('Absent', absent, Colors.red),
                      _buildSummaryItem('Late', late, Colors.orange),
                      _buildSummaryItem('Excused', excused, Colors.blue),
                    ],
                  ),
                ),
              ),

              // ── Bulk-delete selection info bar ────────────────────────────
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
                          style:
                              const TextStyle(color: Colors.red),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  itemBuilder: (context, index) {
                    final player = players[index];
                    final isChecked =
                        _selectedIds.contains(player.id);

                    // In bulk-delete mode wrap in a simple checkable tile.
                    if (_bulkDeleteMode) {
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                backgroundColor: Colors.blue[100],
                                child: Text(
                                  player.displayJersey,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue,
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: player.statusColor,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white,
                                        width: 2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          title: Text(player.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: _buildSubtitle(player),
                          // Checkbox on the RIGHT side of each row.
                          trailing: Checkbox(
                            value: isChecked,
                            activeColor: Colors.red,
                            onChanged: (v) {
                              setState(() {
                                if (v == true) {
                                  _selectedIds.add(player.id);
                                } else {
                                  _selectedIds.remove(player.id);
                                }
                              });
                            },
                          ),
                          onTap: () {
                            setState(() {
                              if (isChecked) {
                                _selectedIds.remove(player.id);
                              } else {
                                _selectedIds.add(player.id);
                              }
                            });
                          },
                        ),
                      );
                    }

                    // ── Normal (non-bulk) player tile ─────────────────────
                    return Dismissible(
                      key: Key(player.id),
                      direction: DismissDirection.endToStart,
                      confirmDismiss: (direction) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete Player'),
                            content: Text(
                              'Are you sure you want to remove '
                              '${player.name} from the roster?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.pop(context, true),
                                style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                      },
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20),
                        child: const Icon(Icons.delete,
                            color: Colors.white, size: 32),
                      ),
                      onDismissed: (_) async {
                        try {
                          await _playerService.deletePlayer(player.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      '${player.name} removed from roster')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    'Error removing player: $e'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                      child: Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                backgroundColor: Colors.blue[100],
                                child: Text(
                                  player.displayJersey,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue,
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: player.statusColor,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white,
                                        width: 2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          title: Text(player.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          subtitle: _buildSubtitle(player),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                                  final newStatus =
                                      player.status == 'present'
                                          ? 'absent'
                                          : 'present';
                                  await _updatePlayerStatus(
                                      player, newStatus);
                                },
                                tooltip: player.status == 'present'
                                    ? 'Mark Absent'
                                    : 'Mark Present',
                              ),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                onSelected: (value) async {
                                  if (value == 'status') {
                                    await _showStatusMenu(player);
                                  } else if (value == 'edit') {
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
                                  } else if (value == 'delete') {
                                    final confirm =
                                        await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title:
                                            const Text('Delete Player'),
                                        content: Text(
                                            'Remove ${player.name} from roster?'),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(
                                                    context, false),
                                            child:
                                                const Text('Cancel'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(
                                                    context, true),
                                            style: FilledButton.styleFrom(
                                                backgroundColor:
                                                    Colors.red),
                                            child:
                                                const Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm == true && mounted) {
                                      await _playerService
                                          .deletePlayer(player.id);
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                              content: Text(
                                                  '${player.name} removed')),
                                        );
                                      }
                                    }
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'status',
                                    child: Row(children: [
                                      Icon(Icons.event_available,
                                          size: 20),
                                      SizedBox(width: 12),
                                      Text('Change Status'),
                                    ]),
                                  ),
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Row(children: [
                                      Icon(Icons.edit, size: 20),
                                      SizedBox(width: 12),
                                      Text('Edit Player'),
                                    ]),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(children: [
                                      Icon(Icons.delete,
                                          color: Colors.red,
                                          size: 20),
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
      // In bulk-delete mode: red "Delete" button.
      // Otherwise: "Add Player" button.
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

  // ── Utility widgets ───────────────────────────────────────────────────────

  Widget _buildSummaryItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.bold, color: color),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
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
      builder: (context) => AlertDialog(
        title: Text(player.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (player.jerseyNumber != null)
              _buildDetailRow('Jersey', player.jerseyNumber!),
            if (player.nickname != null && player.nickname!.isNotEmpty)
              _buildDetailRow('Nickname', player.nickname!),
            if (player.studentId != null && player.studentId!.isNotEmpty)
              _buildDetailRow('Student ID', player.studentId!),
            if (player.studentEmail != null &&
                player.studentEmail!.isNotEmpty)
              _buildDetailRow('Email', player.studentEmail!),
            _buildDetailRow('Status', player.statusLabel),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _showStatusMenu(player);
            },
            icon: Icon(player.statusIcon, size: 16),
            label: const Text('Change Status'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(context);
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

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text('$label:',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}