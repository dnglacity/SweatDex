import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'game_roster_screen.dart';

/// SavedRosterScreen — displays a list of saved game rosters for a team
/// and provides a FAB to create a new one.
///
/// BUG FIX (Bug 2): The `onCancel` callback previously captured `context`
/// from SavedRosterScreen's build method. When GameRosterScreen called
/// `onCancel`, it would pop SavedRosterScreen instead of just GameRosterScreen.
/// Fix: Pass `null` for `onCancel`; GameRosterScreen already has a back button
/// in the AppBar that correctly pops only itself.
///
/// BUG FIX (Issue 2): In `_showCreateRosterDialog()`, the three
/// TextEditingControllers (`titleController`, `dateController`,
/// `starterController`) were disposed unconditionally and immediately after
/// `await showDialog(...)` returned. When the dialog is dismissed via a
/// barrier tap (tapping outside), Flutter may still be processing the
/// dialog's widget teardown for one more frame. During that frame, the
/// TextFormField widgets attempt to call `addListener` on the already-disposed
/// controllers, producing:
///
///   "A TextEditingController was used after being disposed."
///   (saved_roster_screen.dart:73)
///
/// Fix: Move all three `.dispose()` calls into a
/// `WidgetsBinding.instance.addPostFrameCallback` so they run after the
/// current frame — by which time the dialog's widget tree is guaranteed to
/// be fully dismantled. This mirrors the same fix already applied to
/// `_showSlotDialog()` in game_roster_screen.dart.
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
  // ── In-memory roster list ────────────────────────────────────────────────
  // TODO: Replace with a Supabase-backed list once a game_rosters table exists.
  final List<_SavedRoster> _rosters = [];

  // ── Create-roster dialog ─────────────────────────────────────────────────

  /// Opens a form dialog collecting the new roster's metadata.
  /// On confirmation, navigates to [GameRosterScreen] with the provided values.
  Future<void> _showCreateRosterDialog() async {
    // Default title mirrors the common "Team vs. Opponent" match template.
    final titleController =
        TextEditingController(text: '${widget.teamName} vs. ');
    final dateController = TextEditingController();
    final starterController = TextEditingController(text: '5');
    final formKey = GlobalKey<FormState>();

    // Guard against double-submission on Enter key.
    bool submitted = false;

    // Tracks the stepper value in sync with the text field.
    int starterSlots = 5;

    final result = await showDialog<_SavedRoster>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Keep starterSlots in sync when the text field changes.
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
                    // ── Title field ────────────────────────────────────────
                    TextFormField(
                      controller: titleController,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Roster Title *',
                        hintText: 'e.g. Tigers vs. Lions',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.sports_score),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Please enter a title'
                              : null,
                    ),
                    const SizedBox(height: 16),

                    // ── Date field (optional) ──────────────────────────────
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

                    // ── Starter slots: text box + plus/minus stepper ───────
                    Text(
                      'Starting Roster Size',
                      style: Theme.of(ctx).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        // Minus button — decrements down to 1.
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: starterSlots > 1
                              ? () {
                                  setLocal(() {
                                    starterSlots--;
                                    starterController.text = '$starterSlots';
                                  });
                                }
                              : null,
                        ),

                        // Numeric text field — allows typing directly (1–50).
                        Expanded(
                          child: TextFormField(
                            controller: starterController,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            // Allow only digit characters.
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
                              final parsed = int.tryParse(v ?? '');
                              if (parsed == null ||
                                  parsed < 1 ||
                                  parsed > 50) {
                                return '1–50';
                              }
                              return null;
                            },
                          ),
                        ),

                        // Plus button — increments up to 50.
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: starterSlots < 50
                              ? () {
                                  setLocal(() {
                                    starterSlots++;
                                    starterController.text = '$starterSlots';
                                  });
                                }
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Supports 1–50 starters',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(ctx).colorScheme.onSurfaceVariant),
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

    // FIX (Issue 2): Defer all controller disposals to the next frame.
    //
    // Disposing immediately after `await showDialog` is unsafe when the dialog
    // is dismissed via barrier tap, because Flutter may still be processing
    // the dialog's widget teardown for the current frame. During that teardown,
    // TextFormField widgets call `addListener` on their controllers — if the
    // controllers are already disposed, this throws:
    //   "A TextEditingController was used after being disposed."
    //
    // Using `addPostFrameCallback` guarantees the dialog's widget tree is
    // fully dismantled before dispose() is called, matching the fix already
    // applied to `_showSlotDialog()` in game_roster_screen.dart.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      titleController.dispose();
      dateController.dispose();
      starterController.dispose();
    });

    if (result != null && mounted) {
      // Persist the new roster entry to the local list.
      setState(() => _rosters.insert(0, result));

      // BUG FIX (Bug 2): `onCancel: null` — the AppBar back button in
      // GameRosterScreen correctly pops only that screen. Passing a closure
      // that captures this parent context would pop SavedRosterScreen instead.
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GameRosterScreen(
            teamId: widget.teamId,
            teamName: widget.teamName,
            rosterTitle: result.title,
            gameDate: result.gameDate,
            starterSlots: result.starterSlots,
            // null = no "Cancel Roster" bottom button; user uses AppBar back arrow.
            onCancel: null,
          ),
        ),
      );
    }
  }

  /// Opens a roster from the saved list.
  Future<void> _openRoster(_SavedRoster r) async {
    // BUG FIX (Bug 2): Same as above — onCancel: null to avoid wrong-context pop.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GameRosterScreen(
          teamId: widget.teamId,
          teamName: widget.teamName,
          rosterTitle: r.title,
          gameDate: r.gameDate,
          starterSlots: r.starterSlots,
          onCancel: null,
        ),
      ),
    );
  }

  // ── Delete a saved roster ─────────────────────────────────────────────────
  Future<void> _confirmDelete(int index) async {
    final roster = _rosters[index];
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
      setState(() => _rosters.removeAt(index));
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
            Text(
              widget.teamName,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Text(
              'Game Rosters',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: _rosters.isEmpty
          // ── Empty state ──────────────────────────────────────────────────
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.sports_score, size: 72, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text(
                    'No game rosters yet',
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap + to create your first game roster.',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ],
              ),
            )
          // ── Roster list ──────────────────────────────────────────────────
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
                      child: Icon(Icons.sports_score,
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
                        } else if (v == 'delete') {
                          await _confirmDelete(i);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'open',
                          child: Row(children: [
                            Icon(Icons.open_in_new, size: 20),
                            SizedBox(width: 12),
                            Text('Open'),
                          ]),
                        ),
                        const PopupMenuItem(
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

      // ── FAB — Create new game roster ─────────────────────────────────────
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateRosterDialog,
        tooltip: 'New Game Roster',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ── Data model for an in-memory saved roster entry ──────────────────────────
class _SavedRoster {
  final String title;
  final String? gameDate;
  final int starterSlots;
  final DateTime createdAt;

  const _SavedRoster({
    required this.title,
    this.gameDate,
    required this.starterSlots,
    required this.createdAt,
  });
}