import 'package:flutter/material.dart';
import 'package:sweatdex/models/player.dart';
import '../services/player_service.dart';
import 'add_player_screen.dart';

class RosterScreen extends StatefulWidget {
  final String teamId;
  final String teamName; // Added
  final String? sport; // Added (optional)

  const RosterScreen({
    super.key,
    required this.teamId,
    required this.teamName, // Added
    this.sport, // Added
  });

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> {
  final _playerService = PlayerService();

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
        title: Text('${player.name} - Update Status'),
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

  Widget _buildStatusOption(String status, String label, IconData icon, Color color) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      onTap: () => Navigator.pop(context, status),
    );
  }

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

    if (action != null && mounted) {
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
            SnackBar(
              content: Text('Error: $e'),
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
        // Updated to show team name and sport
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
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                ),
              ),
          ],
        ),
        centerTitle: true,
        actions: [
          // Bulk actions button
          IconButton(
            icon: const Icon(Icons.checklist),
            onPressed: _showBulkActions,
            tooltip: 'Bulk Actions',
          ),
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {});
            },
            tooltip: 'Refresh',
          ),
        ],
      ),
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
                  Icon(Icons.people_outline, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text(
                    'No players yet',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap the + button to add your first player!',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ],
              ),
            );
          }

          // Calculate attendance summary
          final present = players.where((p) => p.status == 'present').length;
          final absent = players.where((p) => p.status == 'absent').length;
          final late = players.where((p) => p.status == 'late').length;
          final excused = players.where((p) => p.status == 'excused').length;

          return Column(
            children: [
              // Attendance Summary Card
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

              // Player List
              Expanded(
                child: ListView.builder(
                  itemCount: players.length,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemBuilder: (context, index) {
                    final player = players[index];

                    return Dismissible(
                      key: Key(player.id),
                      direction: DismissDirection.endToStart,
                      confirmDismiss: (direction) async {
                        return await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete Player'),
                            content: Text(
                              'Are you sure you want to remove ${player.name} from the roster?',
                            ),
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
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                      },
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: const Icon(Icons.delete, color: Colors.white, size: 32),
                      ),
                      onDismissed: (direction) async {
                        try {
                          await _playerService.deletePlayer(player.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('${player.name} removed from roster')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error removing player: $e'),
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
                              // Status indicator badge
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: player.statusColor,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          title: Text(
                            player.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: _buildSubtitle(player),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Quick check-in button
                              IconButton(
                                icon: Icon(
                                  player.status == 'present' ? Icons.check_circle : Icons.circle_outlined,
                                  color: player.status == 'present' ? Colors.green : Colors.grey,
                                  size: 28,
                                ),
                                onPressed: () async {
                                  final newStatus = player.status == 'present' ? 'absent' : 'present';
                                  await _updatePlayerStatus(player, newStatus);
                                },
                                tooltip: player.status == 'present' ? 'Mark Absent' : 'Mark Present',
                              ),
                              // More options menu
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                onSelected: (value) async {
                                  if (value == 'status') {
                                    await _showStatusMenu(player);
                                  } else if (value == 'edit') {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => AddPlayerScreen(
                                          teamId: widget.teamId,
                                          playerToEdit: player,
                                        ),
                                      ),
                                    );
                                    if (mounted) {
                                      setState(() {});
                                    }
                                  } else if (value == 'delete') {
                                    final confirm = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: const Text('Delete Player'),
                                        content: Text('Remove ${player.name} from roster?'),
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
                                            child: const Text('Delete'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm == true && mounted) {
                                      await _playerService.deletePlayer(player.id);
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('${player.name} removed')),
                                        );
                                      }
                                    }
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'status',
                                    child: Row(
                                      children: [
                                        Icon(Icons.event_available, size: 20),
                                        SizedBox(width: 12),
                                        Text('Change Status'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Row(
                                      children: [
                                        Icon(Icons.edit, size: 20),
                                        SizedBox(width: 12),
                                        Text('Edit Player'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete, color: Colors.red, size: 20),
                                        SizedBox(width: 12),
                                        Text('Delete', style: TextStyle(color: Colors.red)),
                                      ],
                                    ),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AddPlayerScreen(teamId: widget.teamId),
            ),
          );
          if (mounted) {
            setState(() {});
          }
        },
        icon: const Icon(Icons.person_add),
        label: const Text('Add Player'),
      ),
    );
  }

  Widget _buildSummaryItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
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

    return Text(
      parts.join(' • '),
      style: TextStyle(color: Colors.grey[600]),
    );
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
            if (player.studentEmail != null && player.studentEmail!.isNotEmpty)
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
                  builder: (context) => AddPlayerScreen(
                    teamId: widget.teamId,
                    playerToEdit: player,
                  ),
                ),
              );
              if (mounted) {
                setState(() {});
              }
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
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }
}