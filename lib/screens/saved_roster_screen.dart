import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/player_service.dart';
import '../widgets/error_dialog.dart';
import '../widgets/date_input_field.dart';
import 'game_roster_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// saved_roster_screen.dart  (AOD v1.3)
//
// Lists saved game rosters for a team and lets the coach create new ones.
//
// CHANGE (Notes.txt v1.3): Supabase Realtime via .stream() on game_rosters.
//   Previously the screen used a one-shot Future (_loadRosters) that required
//   a manual reload after returning from GameRosterScreen.  Now it subscribes
//   to PlayerService.getGameRosterStream(teamId) which uses the Supabase
//   Flutter SDK's built-in WebSocket push.  Any change made on another
//   coach's device appears instantly in the list without pulling-to-refresh.
//
//   The stream subscription is stored in [_rosterSub] and cancelled in
//   dispose() to avoid memory leaks.
//
// CHANGE (Notes.txt): Game roster icon changed from Icons.sports_score to
//   Icons.assignment (clipboard) throughout this screen.
//
// CHANGE: Rosters are persisted to and loaded from the Supabase game_rosters
//   table.  The _SavedRoster model carries a Supabase ID so updates and
//   deletes are sent to the DB.
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

  // CHANGE (v1.3): roster list is now driven by a Realtime stream subscription
  // instead of a one-shot Future.
  List<_SavedRoster> _rosters = [];
  bool _loading = true;

  /// Supabase Realtime subscription for game_rosters on this team.
  /// Cancelled in dispose() to prevent memory leaks.
  StreamSubscription<List<Map<String, dynamic>>>? _rosterSub;

  @override
  void initState() {
    super.initState();
    _subscribeToRosters();
  }

  @override
  void dispose() {
    // Always cancel stream subscriptions — failure to do so keeps the
    // WebSocket channel open and causes memory/resource leaks.
    _rosterSub?.cancel();
    super.dispose();
  }

  // ── Realtime subscription ─────────────────────────────────────────────────

  /// Subscribes to game_rosters for this team via the Supabase .stream() API.
  /// Any INSERT/UPDATE/DELETE on the table (by any coach) triggers an event
  /// that updates [_rosters] immediately without a page reload.
  void _subscribeToRosters() {
    _rosterSub = _playerService
        .getGameRosterStream(widget.teamId)
        .listen(
      (rows) {
        // Convert raw Supabase rows to the local _SavedRoster model.
        if (mounted) {
          setState(() {
            _rosters = rows.map(_SavedRoster.fromMap).toList();
            _loading = false;
          });
        }
      },
      onError: (Object e) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Roster stream error: $e')),
          );
        }
      },
    );
  }

  // ── Create roster dialog ──────────────────────────────────────────────────

  Future<void> _showCreateRosterDialog() async {
    // Controllers are created here (inside the method) so each dialog
    // invocation gets fresh instances.
    final titleController =
        TextEditingController(text: '${widget.teamName} vs. ');
    final starterController = TextEditingController(text: '5');
    final formKey = GlobalKey<FormState>();

    bool submitted = false;
    int starterSlots = 5;
    String? dialogDate;

    final result = await showDialog<_SavedRoster>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Sync the stepper int when the text field changes manually.
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
                    // ── Title ────────────────────────────────────────────────
                    TextFormField(
                      controller: titleController,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Roster Title *',
                        hintText: 'e.g. Tigers vs. Lions',
                        border: OutlineInputBorder(),
                        // CHANGE: clipboard icon prefix
                        prefixIcon: Icon(Icons.assignment),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Please enter a title'
                          : null,
                    ),
                    const SizedBox(height: 16),

                    // ── Date (optional) ───────────────────────────────────────
                    Text(
                      'Game Date (optional)',
                      style: Theme.of(ctx).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    DateInputField(
                      onChanged: (v) => setLocal(() => dialogDate = v),
                    ),
                    const SizedBox(height: 16),

                    // ── Starter slots stepper ────────────────────────────────
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
                              if (p == null || p < 1 || p > 50) return '1–50';
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
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant),
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
                        id: null, // DB will assign the UUID
                        title: titleController.text.trim(),
                        gameDate: dialogDate,
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

    // BUG FIX (Issue 2 / Bug 7): Defer disposal to the next frame.
    // Disposing immediately after showDialog returns can trigger a
    // "controller used after dispose" assertion from the animation layer
    // that still holds a reference to the TextField during the close
    // animation frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      titleController.dispose();
      starterController.dispose();
    });

    if (result != null && mounted) {
      try {
        // Persist to Supabase and get the generated UUID back.
        final newId = await _playerService.createGameRoster(
          teamId: widget.teamId,
          title: result.title,
          gameDate: result.gameDate,
          starterSlots: result.starterSlots,
        );

        final saved = result.copyWith(id: newId);

        // The Realtime stream will automatically add this row to [_rosters]
        // once Supabase publishes the INSERT event.  We don't need to call
        // setState manually here.

        // Open the new roster immediately.
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
                // BUG FIX (Bug 2): null — AppBar back pops only GameRosterScreen.
                onCancel: null,
              ),
            ),
          );
          // No manual reload needed — stream fires automatically on return.
        }
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
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
    // Realtime stream handles any changes made while inside the roster.
  }

  // ── Duplicate roster ──────────────────────────────────────────────────────

  Future<void> _showDuplicateDialog(_SavedRoster source) async {
    final titleController =
        TextEditingController(text: '${source.title} (Copy)');
    final formKey = GlobalKey<FormState>();
    bool submitted = false;

    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Duplicate Roster'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: titleController,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'New Roster Name *',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.assignment),
            ),
            onFieldSubmitted: (_) {
              if (!submitted && formKey.currentState!.validate()) {
                submitted = true;
                Navigator.pop(ctx, titleController.text.trim());
              }
            },
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Please enter a name';
              final trimmed = v.trim();
              final duplicate = _rosters.any(
                (r) => r.title.toLowerCase() == trimmed.toLowerCase(),
              );
              if (duplicate) return 'A roster with this name already exists';
              return null;
            },
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
                Navigator.pop(ctx, titleController.text.trim());
              }
            },
            child: const Text('Duplicate'),
          ),
        ],
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      titleController.dispose();
    });

    if (newTitle != null && mounted) {
      try {
        await _playerService.duplicateGameRoster(
          sourceRosterId: source.id!,
          teamId: widget.teamId,
          newTitle: newTitle,
        );
        // Realtime stream will add the new row automatically.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('"$newTitle" created')),
          );
        }
      } catch (e) {
        if (mounted) showErrorDialog(context, e);
      }
    }
  }

  // ── Delete roster ─────────────────────────────────────────────────────────

  Future<void> _confirmDelete(_SavedRoster roster) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Roster'),
        content: Text('Delete "${roster.title}"? This cannot be undone.'),
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
        // Realtime stream will remove the row from the list automatically.
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
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
                style:
                    TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
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
                      Icon(Icons.assignment, size: 72, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      const Text('No game rosters yet',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
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
                          backgroundColor: theme.colorScheme.primaryContainer,
                          // CHANGE: clipboard icon
                          child: Icon(Icons.assignment,
                              color: theme.colorScheme.primary),
                        ),
                        title: Text(r.title,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(r.gameDate != null
                            ? '${r.gameDate} • ${r.starterSlots} starters'
                            : '${r.starterSlots} starters'),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert),
                          onSelected: (v) async {
                            if (v == 'open') {
                              await _openRoster(r);
                            } else if (v == 'duplicate') {
                              await _showDuplicateDialog(r);
                            } else if (v == 'delete') {
                              await _confirmDelete(r);
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
                              value: 'duplicate',
                              child: Row(children: [
                                Icon(Icons.copy, size: 20),
                                SizedBox(width: 12),
                                Text('Duplicate'),
                              ]),
                            ),
                            PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(children: [
                                Icon(Icons.delete, color: Colors.red, size: 20),
                                SizedBox(width: 12),
                                Text('Delete',
                                    style: TextStyle(color: Colors.red)),
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
// Carries an optional `id` from Supabase for persistence and deletion.
// ─────────────────────────────────────────────────────────────────────────────
class _SavedRoster {
  final String? id; // Supabase game_rosters.id (null before first save)
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
          ? DateTime.parse(map['created_at'] as String)
          : DateTime.now(),
    );
  }

  /// Returns a copy with overridden [id].
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