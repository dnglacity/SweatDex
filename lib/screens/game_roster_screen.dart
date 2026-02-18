import 'package:flutter/material.dart';
import 'package:sweatdex/models/player.dart';
import '../services/player_service.dart';

/// GameRosterScreen — build a Starting Lineup and a Substitutes bench
/// by tapping players from the full roster or dragging them into slots.
class GameRosterScreen extends StatefulWidget {
  final String teamId;
  final String teamName;

  const GameRosterScreen({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  @override
  State<GameRosterScreen> createState() => _GameRosterScreenState();
}

class _GameRosterScreenState extends State<GameRosterScreen>
    with SingleTickerProviderStateMixin {
  final PlayerService _playerService = PlayerService();

  List<Player> _allPlayers = [];
  List<Player> _starters = [];
  List<Player> _substitutes = [];
  bool _loading = true;

  late TabController _tabController;

  // How many starters the sport needs (coach can change)
  int _starterSlots = 5;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadPlayers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadPlayers() async {
    try {
      final players = await _playerService.getPlayers(widget.teamId);
      setState(() {
        _allPlayers = players;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading players: $e')),
        );
      }
    }
  }

  /// Players not yet assigned to starters or subs
  List<Player> get _availablePlayers {
    final assignedIds = {
      ..._starters.map((p) => p.id),
      ..._substitutes.map((p) => p.id),
    };
    return _allPlayers.where((p) => !assignedIds.contains(p.id)).toList();
  }

  void _addToStarters(Player player) {
    if (_starters.length >= _starterSlots) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Starting lineup is full ($_starterSlots spots). '
              'Increase the slot count or move a starter to the bench.'),
          action: SnackBarAction(
            label: 'Adjust',
            onPressed: _showSlotDialog,
          ),
        ),
      );
      return;
    }
    setState(() {
      _starters.add(player);
    });
  }

  void _addToSubs(Player player) {
    setState(() {
      _substitutes.add(player);
    });
  }

  void _removeFromStarters(Player player) {
    setState(() {
      _starters.remove(player);
    });
  }

  void _removeFromSubs(Player player) {
    setState(() {
      _substitutes.remove(player);
    });
  }

  void _promoteSubToStarter(Player player) {
    if (_starters.length >= _starterSlots) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Starting lineup is full.')),
      );
      return;
    }
    setState(() {
      _substitutes.remove(player);
      _starters.add(player);
    });
  }

  void _demoteStarterToSub(Player player) {
    setState(() {
      _starters.remove(player);
      _substitutes.add(player);
    });
  }

  void _clearAll() {
    setState(() {
      _starters.clear();
      _substitutes.clear();
    });
  }

  Future<void> _showSlotDialog() async {
    int temp = _starterSlots;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Starting Lineup Size'),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: temp > 1
                    ? () => setLocal(() => temp--)
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text(
                '$temp',
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
              IconButton(
                onPressed: temp < 20
                    ? () => setLocal(() => temp++)
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                setState(() => _starterSlots = temp);
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _saveRoster() {
    // In a future iteration this would persist to Supabase.
    // For now, show a summary dialog.
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Roster Saved'),
        content: Text(
          'Starters (${_starters.length}): ${_starters.map((p) => p.name).join(', ')}\n\n'
          'Subs (${_substitutes.length}): ${_substitutes.map((p) => p.name).join(', ')}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.teamName}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Text(
              'Game Roster Builder',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Set starter slots',
            onPressed: _showSlotDialog,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear all',
            onPressed: _starters.isEmpty && _substitutes.isEmpty
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Clear Roster'),
                        content: const Text(
                            'Remove all players from starters and subs?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            style: FilledButton.styleFrom(
                                backgroundColor: Colors.red),
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) _clearAll();
                  },
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save roster',
            onPressed: _starters.isEmpty ? null : _saveRoster,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.people, size: 16),
                  const SizedBox(width: 6),
                  Text('Available (${_availablePlayers.length})'),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.sports, size: 16),
                  const SizedBox(width: 6),
                  Text('Roster (${_starters.length}/${_starterSlots})'),
                ],
              ),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildAvailableTab(theme),
                _buildRosterTab(theme),
              ],
            ),
    );
  }

  // ─────────────────────────────────────────────
  //  TAB 1 — Available Players
  // ─────────────────────────────────────────────
  Widget _buildAvailableTab(ThemeData theme) {
    final available = _availablePlayers;

    if (_allPlayers.isEmpty) {
      return const Center(
        child: Text('No players on this team yet.\nAdd players from the Roster screen.',
            textAlign: TextAlign.center),
      );
    }

    if (available.isEmpty) {
      return const Center(
        child: Text('All players have been assigned.',
            style: TextStyle(fontStyle: FontStyle.italic)),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Tap a player to add them to the starting lineup or bench. '
            'Long-press and drag to the Roster tab.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: available.length,
            itemBuilder: (_, i) {
              final p = available[i];
              return _DraggablePlayerCard(
                player: p,
                onAddStarter: () => _addToStarters(p),
                onAddSub: () => _addToSubs(p),
              );
            },
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  //  TAB 2 — Roster (Starters + Subs)
  // ─────────────────────────────────────────────
  Widget _buildRosterTab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Starters section ──
          _sectionHeader(
            context: context,
            label: 'Starting Lineup',
            count: _starters.length,
            max: _starterSlots,
            color: theme.colorScheme.primary,
            icon: Icons.star,
          ),
          const SizedBox(height: 8),
          _StarterDropZone(
            starters: _starters,
            starterSlots: _starterSlots,
            onDropPlayer: (p) => _addToStarters(p),
            onRemove: _removeFromStarters,
            onSendToBench: _demoteStarterToSub,
            onReorder: (oldIdx, newIdx) {
              setState(() {
                final p = _starters.removeAt(oldIdx);
                _starters.insert(newIdx, p);
              });
            },
          ),
          const SizedBox(height: 24),

          // ── Substitutes section ──
          _sectionHeader(
            context: context,
            label: 'Substitutes Bench',
            count: _substitutes.length,
            max: null,
            color: theme.colorScheme.secondary,
            icon: Icons.airline_seat_recline_normal,
          ),
          const SizedBox(height: 8),
          _SubsDropZone(
            substitutes: _substitutes,
            onDropPlayer: (p) => _addToSubs(p),
            onRemove: _removeFromSubs,
            onPromote: _promoteSubToStarter,
            onReorder: (oldIdx, newIdx) {
              setState(() {
                final p = _substitutes.removeAt(oldIdx);
                _substitutes.insert(newIdx, p);
              });
            },
          ),

          if (_starters.isEmpty && _substitutes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 32),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.sports_score,
                        size: 64, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text(
                      'Your roster is empty.\nGo to the Available tab to add players.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader({
    required BuildContext context,
    required String label,
    required int count,
    int? max,
    required Color color,
    required IconData icon,
  }) {
    final countStr = max != null ? '$count / $max' : '$count';
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.blue,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            countStr,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.bold, color: color),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
//  _DraggablePlayerCard — shown in the Available tab
// ──────────────────────────────────────────────────────────────────────────
class _DraggablePlayerCard extends StatelessWidget {
  final Player player;
  final VoidCallback onAddStarter;
  final VoidCallback onAddSub;

  const _DraggablePlayerCard({
    required this.player,
    required this.onAddStarter,
    required this.onAddSub,
  });

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<Player>(
      data: player,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 240,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: Text(
                  player.jerseyNumber ?? '?',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  player.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: _buildCard(context),
      ),
      child: _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            player.jerseyNumber ?? '?',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontSize: 12,
            ),
          ),
        ),
        title: Text(player.name, style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: player.nickname != null
            ? Text('"${player.nickname}"',
                style: const TextStyle(fontStyle: FontStyle.italic))
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'Add to starters',
              child: IconButton(
                icon: const Icon(Icons.star_outline, size: 20),
                onPressed: onAddStarter,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            Tooltip(
              message: 'Add to bench',
              child: IconButton(
                icon: const Icon(Icons.airline_seat_recline_normal, size: 20),
                onPressed: onAddSub,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
//  _StarterDropZone — reorderable list of starters
// ──────────────────────────────────────────────────────────────────────────
class _StarterDropZone extends StatelessWidget {
  final List<Player> starters;
  final int starterSlots;
  final ValueChanged<Player> onDropPlayer;
  final ValueChanged<Player> onRemove;
  final ValueChanged<Player> onSendToBench;
  final void Function(int oldIdx, int newIdx) onReorder;

  const _StarterDropZone({
    required this.starters,
    required this.starterSlots,
    required this.onDropPlayer,
    required this.onRemove,
    required this.onSendToBench,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFull = starters.length >= starterSlots;

    return DragTarget<Player>(
      onWillAcceptWithDetails: (details) =>
          !starters.contains(details.data) && !isFull,
      onAcceptWithDetails: (details) => onDropPlayer(details.data),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isHovering
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : theme.colorScheme.surface,
            border: Border.all(
              color: isHovering
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.03),
              width: isHovering ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: starters.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      isFull
                          ? 'Lineup full'
                          : 'Drag players here or tap ★ on the Available tab',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: starters.length,
                  onReorder: onReorder,
                  itemBuilder: (_, i) {
                    final p = starters[i];
                    return _RosterRowTile(
                      key: ValueKey(p.id),
                      player: p,
                      slotNumber: i + 1,
                      accentColor: theme.colorScheme.primary,
                      trailingActions: [
                        Tooltip(
                          message: 'Move to bench',
                          child: IconButton(
                            icon: const Icon(
                                Icons.airline_seat_recline_normal,
                                size: 18),
                            onPressed: () => onSendToBench(p),
                          ),
                        ),
                        Tooltip(
                          message: 'Remove from roster',
                          child: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            color: Colors.red,
                            onPressed: () => onRemove(p),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
//  _SubsDropZone — reorderable bench list
// ──────────────────────────────────────────────────────────────────────────
class _SubsDropZone extends StatelessWidget {
  final List<Player> substitutes;
  final ValueChanged<Player> onDropPlayer;
  final ValueChanged<Player> onRemove;
  final ValueChanged<Player> onPromote;
  final void Function(int oldIdx, int newIdx) onReorder;

  const _SubsDropZone({
    required this.substitutes,
    required this.onDropPlayer,
    required this.onRemove,
    required this.onPromote,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DragTarget<Player>(
      onWillAcceptWithDetails: (details) =>
          !substitutes.contains(details.data),
      onAcceptWithDetails: (details) => onDropPlayer(details.data),
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isHovering
                ? theme.colorScheme.secondary.withValues(alpha: 0.08)
                : theme.colorScheme.surface,
            border: Border.all(
              color: isHovering
                  ? theme.colorScheme.secondary
                  : theme.colorScheme.outline.withValues(alpha: 0.03),
              width: isHovering ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: substitutes.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'Drag players here or tap the bench icon on the Available tab',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: substitutes.length,
                  onReorder: onReorder,
                  itemBuilder: (_, i) {
                    final p = substitutes[i];
                    return _RosterRowTile(
                      key: ValueKey(p.id),
                      player: p,
                      slotNumber: i + 1,
                      accentColor: theme.colorScheme.secondary,
                      trailingActions: [
                        Tooltip(
                          message: 'Promote to starter',
                          child: IconButton(
                            icon: const Icon(Icons.star_outline, size: 18),
                            onPressed: () => onPromote(p),
                          ),
                        ),
                        Tooltip(
                          message: 'Remove from bench',
                          child: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            color: Colors.red,
                            onPressed: () => onRemove(p),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
//  _RosterRowTile — shared tile used inside both reorderable lists
// ──────────────────────────────────────────────────────────────────────────
class _RosterRowTile extends StatelessWidget {
  final Player player;
  final int slotNumber;
  final Color accentColor;
  final List<Widget> trailingActions;

  const _RosterRowTile({
    super.key,
    required this.player,
    required this.slotNumber,
    required this.accentColor,
    required this.trailingActions,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          const Icon(Icons.drag_handle, color: Colors.grey, size: 20),
          const SizedBox(width: 6),
          CircleAvatar(
            radius: 16,
            backgroundColor: accentColor.withValues(alpha: 0.15),
            child: Text(
              player.jerseyNumber ?? '?',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: accentColor,
              ),
            ),
          ),
        ],
      ),
      title: Text(player.name,
          style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: player.nickname != null
          ? Text('"${player.nickname}"',
              style: const TextStyle(
                  fontStyle: FontStyle.italic, fontSize: 12))
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: trailingActions,
      ),
    );
  }
}