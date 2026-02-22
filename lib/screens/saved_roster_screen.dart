import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/player_service.dart';
import 'game_roster_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// saved_roster_screen.dart
//
// Lists saved game rosters for a team and lets the coach create new ones.
//
// CHANGE (Notes.txt): Game roster icon changed from Icons.sports_score to
//   Icons.assignment (clipboard) throughout this screen.
//
// CHANGE: Rosters are now persisted to and loaded from the Supabase
//   game_rosters table (defined in migration_v2.sql) instead of an
//   in-memory list. The _SavedRoster model now carries a Supabase ID so
//   updates and deletes are sent to the DB.
//
// BUG FIX (Issue 2 / Bug 7): TextEditingController.dispose() is deferred
//   to the next frame via addPostFrameCallback to avoid "used after dispose"
//   errors when the dialog is dismissed via barrier tap.
//
// BUG FIX (Bug 2): onCancel: null — GameRosterScreen's AppBar back button
//   correctly pops only itself; passing a parent-context closure would pop
//   SavedRosterScreen instead.
// ─────────────────────────────────────────────────────────────────────────────

class SavedRosterScreen extends StatefulWidget {
  final String teamId;
  final String teamName;

  const SavedRosterScreen({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  @override
  State<SavedRosterScreen> createState() => _SavedRosterScreenState();
}

class _SavedRosterScreenState extends State<SavedRosterScreen> {
  final _playerService = PlayerService();

  // The roster list is loaded from Supabase.
  List<_SavedRoster> _rosters = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRosters();
  }

  // ── Load from Supabase ────────────────────────────────────────────────────

  Future<void> _loadRosters() async {
    setState(() => _loading = true);
    try {
      final data = await _playerService.getGameRosters(widget.teamId);
      setState(() {
        _rosters = data.map(_SavedRoster.fromMap).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading rosters: $e')),
        );
      }
    }
  }

  // ── Create roster dialog ──────────────────────────────────────────────────

  Future<void> _showCreateRosterDialog() async {
    final titleController =
        TextEditingController(text: '${widget.teamName} vs. ');
    final dateController = TextEditingController();
    final starterController = TextEditingController(text: '5');
    final formKey = GlobalKey<FormState>();

    bool submitted = false;
    int starterSlots = 5;

    final result = await showDialog<_SavedRoster>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          void syncSlots(String value) {
            final parsed = int.tryParse(value);
            if (parsed != null && parsed >= 1 && parsed <= 50) {
              setLocal(() => starterSlots = parsed);
            }
          }

          return AlertDialog(
            title: const Text('New Game Roster'),
            content: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title field.
                    TextFormField(
                      controller: titleController,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Roster Title *',
                        hintText: 'e.g. Tigers vs. Lions',
                        border: OutlineInputBorder(),
                        // CHANGE: clipboard icon
                        prefixIcon: Icon(Icons.assignment),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Please enter a title'
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // Date field (optional).
                    TextFormField(
                      controller: dateController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Game Date (optional)',
                        hintText: 'e.g. 2026-03-15',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.calendar_today),
                      ),
                      keyboardType: TextInputType.datetime,
                    ),
                    const SizedBox(height: 16),

                    // Starter slots stepper.
                    Text(
                      'Starting Roster Size',
                      style: Theme.of(ctx).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: starterSlots > 1
                              ? () => setLocal(() {
                                    starterSlots--;
                                    starterController.text = '$starterSlots';
                                  })
                              : null,
                        ),
                        Expanded(
                          child: TextFormField(
                            controller: starterController,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 12),
                            ),
                            onChanged: syncSlots,
                            validator: (v) {
                              final p = int.tryParse(v ?? '');
                              if (p == null || p < 1 || p > 50) {
                                return '1–50';
                              }
                              return null;
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: starterSlots < 50
                              ? () => setLocal(() {
                                    starterSlots++;
                                    starterController.text = '$starterSlots';
                                  })
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Supports 1–50 starters',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          color: Theme.of(ctx)
                              .colorScheme
                              .onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (!submitted && formKey.currentState!.validate()) {
                    submitted = true;
                    final parsed =
                        int.tryParse(starterController.text) ?? 5;
                    Navigator.pop(
                      ctx,
                      _SavedRoster(
                        id: null, // DB will assign
                        title: titleController.text.trim(),
                        gameDate: dateController.text.trim().isEmpty
                            ? null
                            : dateController.text.trim(),
                        starterSlots: parsed.clamp(1, 50),
                        createdAt: DateTime.now(),
                      ),
                    );
                  }
                },
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );

    // BUG FIX (Issue 2 / Bug 7): Defer disposal to next frame to avoid
    // "controller used after dispose" when dialog dismissed via barrier.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      titleController.dispose();
      dateController.dispose();
      starterController.dispose();
    });

    if (result != null && mounted) {
      try {
        // Persist to Supabase and capture the generated ID.
        final newId = await _playerService.createGameRoster(
          teamId: widget.teamId,
          title: result.title,
          gameDate: result.gameDate,
          starterSlots: result.starterSlots,
        );

        final saved = result.copyWith(id: newId);
        setState(() => _rosters.insert(0, saved));

        // BUG FIX (Bug 2): onCancel: null so AppBar back button only pops
        // GameRosterScreen, not SavedRosterScreen.
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GameRosterScreen(
                teamId: widget.teamId,
                teamName: widget.teamName,
                rosterTitle: saved.title,
                gameDate: saved.gameDate,
                starterSlots: saved.starterSlots,
                rosterId: saved.id,
                onCancel: null,
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Error saving roster: $e'),
                backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  // ── Open existing roster ──────────────────────────────────────────────────

  Future<void> _openRoster(_SavedRoster r) async {
    // BUG FIX (Bug 2): onCancel: null — same reasoning as above.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GameRosterScreen(
          teamId: widget.teamId,
          teamName: widget.teamName,
          rosterTitle: r.title,
          gameDate: r.gameDate,
          starterSlots: r.starterSlots,
          rosterId: r.id,
          onCancel: null,
        ),
      ),
    );
    // Reload after returning in case starters/subs were modified and saved.
    await _loadRosters();
  }

  // ── Delete roster ─────────────────────────────────────────────────────────

  Future<void> _confirmDelete(int index) async {
    final roster = _rosters[index];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Roster'),
        content:
            Text('Delete "${roster.title}"? This cannot be undone.'),
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
        if (roster.id != null) {
          await _playerService.deleteGameRoster(roster.id!);
        }
        setState(() => _rosters.removeAt(index));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Error deleting: $e'),
                backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.teamName,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const Text('Game Rosters',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rosters.isEmpty
              // ── Empty state ────────────────────────────────────────────────
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // CHANGE: clipboard icon
                      Icon(Icons.assignment,
                          size: 72, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      const Text('No game rosters yet',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(
                        'Tap + to create your first game roster.',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                )
              // ── Roster list ────────────────────────────────────────────────
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _rosters.length,
                  itemBuilder: (_, i) {
                    final r = _rosters[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              theme.colorScheme.primaryContainer,
                          // CHANGE: clipboard icon
                          child: Icon(Icons.assignment,
                              color: theme.colorScheme.primary),
                        ),
                        title: Text(r.title,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        subtitle: Text(r.gameDate != null
                            ? '${r.gameDate} • ${r.starterSlots} starters'
                            : '${r.starterSlots} starters'),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert),
                          onSelected: (v) async {
                            if (v == 'open') {
                              await _openRoster(r);
                            } else if (v == 'delete') {
                              await _confirmDelete(i);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'open',
                              child: Row(children: [
                                Icon(Icons.open_in_new, size: 20),
                                SizedBox(width: 12),
                                Text('Open'),
                              ]),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(children: [
                                Icon(Icons.delete,
                                    color: Colors.red, size: 20),
                                SizedBox(width: 12),
                                Text('Delete',
                                    style:
                                        TextStyle(color: Colors.red)),
                              ]),
                            ),
                          ],
                        ),
                        onTap: () => _openRoster(r),
                      ),
                    );
                  },
                ),

      // FAB — Create new game roster.
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateRosterDialog,
        tooltip: 'New Game Roster',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Local model for a saved game roster entry.
// Now carries an optional `id` from Supabase for persistence.
// ─────────────────────────────────────────────────────────────────────────────
class _SavedRoster {
  final String? id;       // Supabase game_rosters.id (null before first save)
  final String title;
  final String? gameDate;
  final int starterSlots;
  final DateTime createdAt;

  const _SavedRoster({
    required this.id,
    required this.title,
    this.gameDate,
    required this.starterSlots,
    required this.createdAt,
  });

  /// Constructs from a Supabase row map.
  factory _SavedRoster.fromMap(Map<String, dynamic> map) {
    return _SavedRoster(
      id: map['id'] as String?,
      title: map['title'] as String,
      gameDate: map['game_date'] as String?,
      starterSlots: (map['starter_slots'] as int?) ?? 5,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'])
          : DateTime.now(),
    );
  }

  /// Returns a copy with overridden fields.
  _SavedRoster copyWith({String? id}) {
    return _SavedRoster(
      id: id ?? this.id,
      title: title,
      gameDate: gameDate,
      starterSlots: starterSlots,
      createdAt: createdAt,
    );
  }
}