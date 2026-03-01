import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// BUG FIX: corrected package import to relative path.
// The original file used `package:sweatdex/models/player.dart` which is an
// absolute package-name import. All other screens in this project use relative
// imports (e.g. `../models/player.dart`). While both forms work when the
// package name matches pubspec.yaml (`name: sweatdex`), mixing styles causes
// the analyzer to report inconsistencies and can break on rename/refactor.
// Standardised to relative import to match the rest of the codebase.
import '../models/player.dart';
import '../services/player_service.dart';
import '../widgets/error_dialog.dart';
import '../widgets/date_input_field.dart';

// ─────────────────────────────────────────────────────────────────────────────
// game_roster_screen.dart  (AOD v1.4)
//
// CHANGE (Notes.txt v1.4 — Tab lazy loading):
//   Both tab bodies are extracted into dedicated StatefulWidget classes
//   (_AvailableTabView and _RosterTabView) that mix in
//   AutomaticKeepAliveClientMixin.  This prevents the Available-players list
//   from re-rendering every time the coach switches to the Roster tab and back.
//   State (scroll position, loaded data) is preserved across tab switches.
//
// CHANGE (Notes.txt v1.4 — Editable positions on game roster):
//   Each player tile in the Starting Lineup and Substitutes lists now shows a
//   tappable "position" chip beneath the player name.  Tapping it opens a
//   compact inline text field to temporarily override the position for this
//   game roster session only.  The override is stored in a local Map
//   (_positionOverrides) keyed by player.id and is included in the saved
//   roster JSON as a `position_override` key alongside `player_id` and
//   `slot_number`.  Overrides are restored when reopening a saved roster.
//
// Retained from v1.3:
//   • Clipboard icon throughout.
//   • White tab text on blue AppBar.
//   • Saved roster restore via getGameRosterById().
//   • BUG FIX (Bug 7): deferred TextEditingController.dispose().
// ─────────────────────────────────────────────────────────────────────────────

class GameRosterScreen extends StatefulWidget {
  final String teamId;
  final String teamName;
  final String? rosterTitle;
  final String? gameDate;
  final int starterSlots;
  final String? rosterId;
  final VoidCallback? onCancel;

  const GameRosterScreen({
    super.key,
    required this.teamId,
    required this.teamName,
    this.rosterTitle,
    this.gameDate,
    this.starterSlots = 5,
    this.rosterId,
    this.onCancel,
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
  late int _starterSlots;

  // CHANGE (v1.4): Per-game position overrides — keyed by player.id.
  // These are temporary session overrides; they do NOT alter the player DB row.
  final Map<String, String> _positionOverrides = {};

  // Mutable game date — updated via the settings menu.
  late String? _gameDate;

  @override
  void initState() {
    super.initState();
    _starterSlots = widget.starterSlots;
    _gameDate = widget.gameDate;
    _tabController = TabController(length: 2, vsync: this);
    _loadPlayers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  Future<void> _loadPlayers() async {
    try {
      final players = await _playerService.getPlayers(widget.teamId);

      if (widget.rosterId != null) {
        final rosterData =
            await _playerService.getGameRosterById(widget.rosterId!);
        if (rosterData != null) {
          final starterIds = _extractOrderedIds(rosterData['starters']);
          final subIds = _extractOrderedIds(rosterData['substitutes']);
          final playerMap = {for (final p in players) p.id: p};

          // CHANGE (v1.4): Restore position overrides from saved JSON.
          _restorePositionOverrides(rosterData['starters']);
          _restorePositionOverrides(rosterData['substitutes']);

          setState(() {
            _allPlayers = players;
            _starters = starterIds
                .where((id) => playerMap.containsKey(id))
                .map((id) => playerMap[id]!)
                .toList();
            _substitutes = subIds
                .where((id) => playerMap.containsKey(id))
                .map((id) => playerMap[id]!)
                .toList();
            final savedSlots = rosterData['starter_slots'];
            if (savedSlots is int && savedSlots > 0) {
              _starterSlots = savedSlots;
            }
            _loading = false;
          });
          return;
        }
      }

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

  // ── ID extraction helpers ─────────────────────────────────────────────────

  List<String> _extractOrderedIds(dynamic raw) {
    if (raw == null) return [];
    final list = raw as List;
    final sorted = List<Map<String, dynamic>>.from(list)
      ..sort((a, b) =>
          ((a['slot_number'] ?? 0) as int)
              .compareTo((b['slot_number'] ?? 0) as int));
    return sorted
        .map((m) => (m['player_id'] ?? '') as String)
        .where((id) => id.isNotEmpty)
        .toList();
  }

  // CHANGE (v1.4): Read position_override from each saved slot entry.
  void _restorePositionOverrides(dynamic raw) {
    if (raw == null) return;
    for (final slot in raw as List) {
      final id = slot['player_id'] as String? ?? '';
      final override = slot['position_override'] as String?;
      if (id.isNotEmpty && override != null && override.isNotEmpty) {
        _positionOverrides[id] = override;
      }
    }
  }

  // ── Available players ─────────────────────────────────────────────────────

  List<Player> get _availablePlayers {
    final assigned = {
      ..._starters.map((p) => p.id),
      ..._substitutes.map((p) => p.id),
    };
    return _allPlayers.where((p) => !assigned.contains(p.id)).toList();
  }

  // ── Assignment ────────────────────────────────────────────────────────────

  void _addToStarters(Player player) {
    if (_starters.length >= _starterSlots) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Lineup full ($_starterSlots spots). Adjust or bench a starter.'),
          action: SnackBarAction(label: 'Adjust', onPressed: _showSlotDialog),
        ),
      );
      return;
    }
    setState(() => _starters.add(player));
  }

  void _addToSubs(Player player) => setState(() => _substitutes.add(player));
  void _removeFromStarters(Player p) => setState(() => _starters.remove(p));
  void _removeFromSubs(Player p) => setState(() => _substitutes.remove(p));

  void _promoteSubToStarter(Player player) {
    if (_starters.length >= _starterSlots) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Starting lineup is full.')));
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

  void _clearAll() => setState(() {
        _starters.clear();
        _substitutes.clear();
        _positionOverrides.clear(); // CHANGE (v1.4): clear overrides too
      });

  // ── Position override edit ────────────────────────────────────────────────

  /// CHANGE (v1.4): Shows an inline bottom sheet for a coach to temporarily
  /// override a player's position for this game roster only.
  Future<void> _editPositionOverride(Player player) async {
    final controller = TextEditingController(
      // Pre-fill with existing override, then player's default position.
      text: _positionOverrides[player.id] ?? player.position ?? '',
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // allows keyboard to push sheet up
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Position override for ${player.name}',
              style: Theme.of(ctx)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'This only changes the displayed position for this game roster. '
              "It does not edit the player's profile.",
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Position (game override)',
                hintText: 'e.g., Point Guard, Pitcher, Sweeper',
                prefixIcon: Icon(Icons.sports),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    // Clear override — revert to player's default.
                    setState(() => _positionOverrides.remove(player.id));
                    Navigator.pop(ctx);
                  },
                  child: const Text('Clear'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final text = controller.text.trim();
                    setState(() {
                      if (text.isEmpty) {
                        _positionOverrides.remove(player.id);
                      } else {
                        _positionOverrides[player.id] = text;
                      }
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    // BUG FIX (Bug 7 pattern): defer dispose to next frame.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => controller.dispose());
  }

  // ── Slot-count dialog ─────────────────────────────────────────────────────

  Future<void> _showSlotDialog() async {
    int temp = _starterSlots;
    final controller = TextEditingController(text: '$temp');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          void onTextChanged(String value) {
            final parsed = int.tryParse(value);
            if (parsed != null && parsed >= 1 && parsed <= 50) {
              setLocal(() => temp = parsed);
            }
          }

          return AlertDialog(
            title: const Text('Starting Lineup Size'),
            content: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: temp > 1
                      ? () => setLocal(() {
                            temp--;
                            controller.text = '$temp';
                          })
                      : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                SizedBox(
                  width: 72,
                  child: TextField(
                    controller: controller,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    onChanged: onTextChanged,
                  ),
                ),
                IconButton(
                  onPressed: temp < 50
                      ? () => setLocal(() {
                            temp++;
                            controller.text = '$temp';
                          })
                      : null,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final parsed = int.tryParse(controller.text);
                  if (parsed != null && parsed >= 1 && parsed <= 50) {
                    setState(() => _starterSlots = parsed);
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    // BUG FIX (Bug 7): defer dispose.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => controller.dispose());
  }

  // ── Date dialog ───────────────────────────────────────────────────────────

  Future<void> _showDateDialog() async {
    // Tracks the value emitted by DateInputField while the dialog is open.
    // Seeded with the current date so "Save" with no changes is a no-op.
    String? pendingDate = _gameDate;

    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Change Game Date'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DateInputField(
                initialValue: _gameDate,
                onChanged: (v) => pendingDate = v,
              ),
              const SizedBox(height: 8),
              Text(
                'Leave all fields blank to clear the date.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Clear'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, pendingDate ?? ''),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;

    final newDate = result.isEmpty ? null : result;
    setState(() => _gameDate = newDate);

    if (widget.rosterId != null) {
      try {
        await _playerService.updateGameRosterMeta(
          rosterId: widget.rosterId!,
          gameDate: newDate,
        );
      } catch (e) {
        if (mounted) showErrorDialog(context, e);
      }
    }
  }

  // ── Save roster ───────────────────────────────────────────────────────────

  Future<void> _saveRoster() async {
    if (_starters.length > _starterSlots) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Too Many Starters'),
          content: Text(
            '${_starters.length} starters exceed the roster size of $_starterSlots. '
            'Bench or remove a starter, or increase the roster size before saving.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    if (widget.rosterId != null) {
      try {
        // CHANGE (v1.4): Include position_override in each slot entry.
        final starterData = [
          for (int i = 0; i < _starters.length; i++)
            {
              'player_id': _starters[i].id,
              'slot_number': i + 1,
              if (_positionOverrides.containsKey(_starters[i].id))
                'position_override': _positionOverrides[_starters[i].id],
            },
        ];
        final subData = [
          for (int i = 0; i < _substitutes.length; i++)
            {
              'player_id': _substitutes[i].id,
              'slot_number': i + 1,
              if (_positionOverrides.containsKey(_substitutes[i].id))
                'position_override': _positionOverrides[_substitutes[i].id],
            },
        ];

        await _playerService.updateGameRosterLineup(
          rosterId: widget.rosterId!,
          starters: starterData,
          substitutes: subData,
          starterSlots: _starterSlots,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Roster saved!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
        }
      }
    } else {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Roster Summary'),
          content: Text(
            'Starters (${_starters.length}): '
            '${_starters.map((p) => p.name).join(', ')}\n\n'
            'Subs (${_substitutes.length}): '
            '${_substitutes.map((p) => p.name).join(', ')}',
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
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final displayTitle = widget.rosterTitle ?? widget.teamName;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              displayTitle,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (_gameDate != null && _gameDate!.isNotEmpty)
              Text(_gameDate!,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.normal))
            else
              const Text('Game Roster Builder',
                  style:
                      TextStyle(fontSize: 11, fontWeight: FontWeight.normal)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.settings),
            tooltip: 'Roster settings',
            onSelected: (v) async {
              if (v == 'slots') {
                await _showSlotDialog();
              } else if (v == 'date') {
                await _showDateDialog();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'slots',
                child: Row(children: [
                  Icon(Icons.format_list_numbered, size: 20),
                  SizedBox(width: 12),
                  Text('Starter Slots'),
                ]),
              ),
              PopupMenuItem(
                value: 'date',
                child: Row(children: [
                  Icon(Icons.calendar_today, size: 20),
                  SizedBox(width: 12),
                  Text('Change Date'),
                ]),
              ),
            ],
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
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white.withValues(alpha: 0.7),
          indicatorColor: Colors.white,
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
                  const Icon(Icons.assignment, size: 16),
                  const SizedBox(width: 6),
                  Text('Roster (${_starters.length}/$_starterSlots)'),
                ],
              ),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          // CHANGE (v1.4): TabBarView children are now separate StatefulWidgets
          // that implement AutomaticKeepAliveClientMixin.  This prevents the
          // Available-players list from re-rendering on every tab switch.
          : TabBarView(
              controller: _tabController,
              children: [
                _AvailableTabView(
                  allPlayers: _allPlayers,
                  availablePlayers: _availablePlayers,
                  onAddStarter: _addToStarters,
                  onAddSub: _addToSubs,
                ),
                _RosterTabView(
                  starters: _starters,
                  substitutes: _substitutes,
                  starterSlots: _starterSlots,
                  positionOverrides: _positionOverrides,
                  onDropToStarters: _addToStarters,
                  onDropToSubs: _addToSubs,
                  onRemoveStarter: _removeFromStarters,
                  onRemoveSub: _removeFromSubs,
                  onSendToBench: _demoteStarterToSub,
                  onPromote: _promoteSubToStarter,
                  onReorderStarters: (old, neo) {
                    setState(() {
                      final p = _starters.removeAt(old);
                      _starters.insert(neo, p);
                    });
                  },
                  onReorderSubs: (old, neo) {
                    setState(() {
                      final p = _substitutes.removeAt(old);
                      _substitutes.insert(neo, p);
                    });
                  },
                  onEditPosition: _editPositionOverride, // CHANGE (v1.4)
                ),
              ],
            ),
      bottomNavigationBar: widget.onCancel != null
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: OutlinedButton.icon(
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.close),
                  label: const Text('Cancel Roster'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AvailableTabView  (CHANGE v1.4 — lazy loading via keep-alive mixin)
// ─────────────────────────────────────────────────────────────────────────────
class _AvailableTabView extends StatefulWidget {
  final List<Player> allPlayers;
  final List<Player> availablePlayers;
  final ValueChanged<Player> onAddStarter;
  final ValueChanged<Player> onAddSub;

  const _AvailableTabView({
    required this.allPlayers,
    required this.availablePlayers,
    required this.onAddStarter,
    required this.onAddSub,
  });

  @override
  State<_AvailableTabView> createState() => _AvailableTabViewState();
}

class _AvailableTabViewState extends State<_AvailableTabView>
    with AutomaticKeepAliveClientMixin {

  // Keeps this tab's state alive when the user switches to the Roster tab.
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // Required call when using AutomaticKeepAliveClientMixin.
    super.build(context);

    final theme = Theme.of(context);
    final available = widget.availablePlayers;

    if (widget.allPlayers.isEmpty) {
      return const Center(
        child: Text(
          'No players on this team yet.\nAdd players from the Roster screen.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (available.isEmpty) {
      return const Center(
        child: Text(
          'All players have been assigned.',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
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
                onAddStarter: () => widget.onAddStarter(p),
                onAddSub: () => widget.onAddSub(p),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _RosterTabView  (CHANGE v1.4 — lazy loading + editable positions)
// ─────────────────────────────────────────────────────────────────────────────
class _RosterTabView extends StatefulWidget {
  final List<Player> starters;
  final List<Player> substitutes;
  final int starterSlots;
  final Map<String, String> positionOverrides;
  final ValueChanged<Player> onDropToStarters;
  final ValueChanged<Player> onDropToSubs;
  final ValueChanged<Player> onRemoveStarter;
  final ValueChanged<Player> onRemoveSub;
  final ValueChanged<Player> onSendToBench;
  final ValueChanged<Player> onPromote;
  final void Function(int, int) onReorderStarters;
  final void Function(int, int) onReorderSubs;
  final ValueChanged<Player> onEditPosition; // CHANGE (v1.4)

  const _RosterTabView({
    required this.starters,
    required this.substitutes,
    required this.starterSlots,
    required this.positionOverrides,
    required this.onDropToStarters,
    required this.onDropToSubs,
    required this.onRemoveStarter,
    required this.onRemoveSub,
    required this.onSendToBench,
    required this.onPromote,
    required this.onReorderStarters,
    required this.onReorderSubs,
    required this.onEditPosition,
  });

  @override
  State<_RosterTabView> createState() => _RosterTabViewState();
}

class _RosterTabViewState extends State<_RosterTabView>
    with AutomaticKeepAliveClientMixin {

  // Keeps this tab's state alive across tab switches.
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin.

    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            context: context,
            label: 'Starting Lineup',
            count: widget.starters.length,
            max: widget.starterSlots,
            color: theme.colorScheme.primary,
            icon: Icons.star,
          ),
          const SizedBox(height: 8),
          _StarterDropZone(
            starters: widget.starters,
            starterSlots: widget.starterSlots,
            positionOverrides: widget.positionOverrides,
            onDropPlayer: widget.onDropToStarters,
            onRemove: widget.onRemoveStarter,
            onSendToBench: widget.onSendToBench,
            onEditPosition: widget.onEditPosition,
            onReorder: widget.onReorderStarters,
          ),
          const SizedBox(height: 24),
          _sectionHeader(
            context: context,
            label: 'Substitutes Bench',
            count: widget.substitutes.length,
            max: null,
            color: theme.colorScheme.secondary,
            icon: Icons.airline_seat_recline_normal,
          ),
          const SizedBox(height: 8),
          _SubsDropZone(
            substitutes: widget.substitutes,
            positionOverrides: widget.positionOverrides,
            onDropPlayer: widget.onDropToSubs,
            onRemove: widget.onRemoveSub,
            onPromote: widget.onPromote,
            onEditPosition: widget.onEditPosition,
            onReorder: widget.onReorderSubs,
          ),
          if (widget.starters.isEmpty && widget.substitutes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 32),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.assignment, size: 64, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    Text(
                      'Your roster is empty.\n'
                      'Go to the Available tab to add players.',
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
            color: color.withValues(alpha: 0.15),
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

// ─────────────────────────────────────────────────────────────────────────────
// _DraggablePlayerCard — shown in the Available tab
// ─────────────────────────────────────────────────────────────────────────────
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
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                child: Text(player.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging:
          Opacity(opacity: 0.3, child: _buildCard(context)),
      child: _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            player.jerseyNumber ?? '?',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontSize: 12,
            ),
          ),
        ),
        title: Text(player.name,
            style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: _buildSubtitle(),
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
                icon: const Icon(
                    Icons.airline_seat_recline_normal,
                    size: 20),
                onPressed: onAddSub,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _buildSubtitle() {
    final parts = <String>[];
    if (player.position != null && player.position!.isNotEmpty) {
      parts.add(player.position!);
    }
    if (player.nickname != null && player.nickname!.isNotEmpty) {
      parts.add('"${player.nickname}"');
    }
    if (parts.isEmpty) return null;
    return Text(parts.join(' • '),
        style: const TextStyle(fontStyle: FontStyle.italic));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _StarterDropZone
// ─────────────────────────────────────────────────────────────────────────────
class _StarterDropZone extends StatelessWidget {
  final List<Player> starters;
  final int starterSlots;
  final Map<String, String> positionOverrides;
  final ValueChanged<Player> onDropPlayer;
  final ValueChanged<Player> onRemove;
  final ValueChanged<Player> onSendToBench;
  final ValueChanged<Player> onEditPosition;
  final void Function(int, int) onReorder;

  const _StarterDropZone({
    required this.starters,
    required this.starterSlots,
    required this.positionOverrides,
    required this.onDropPlayer,
    required this.onRemove,
    required this.onSendToBench,
    required this.onEditPosition,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFull = starters.length >= starterSlots;

    return DragTarget<Player>(
      onWillAcceptWithDetails: (d) =>
          !starters.contains(d.data) && !isFull,
      onAcceptWithDetails: (d) => onDropPlayer(d.data),
      builder: (_, candidateData, _) {
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
                          fontStyle: FontStyle.italic),
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
                      positionOverrides: positionOverrides,
                      onEditPosition: onEditPosition,
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
                          message: 'Remove',
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

// ─────────────────────────────────────────────────────────────────────────────
// _SubsDropZone
// ─────────────────────────────────────────────────────────────────────────────
class _SubsDropZone extends StatelessWidget {
  final List<Player> substitutes;
  final Map<String, String> positionOverrides;
  final ValueChanged<Player> onDropPlayer;
  final ValueChanged<Player> onRemove;
  final ValueChanged<Player> onPromote;
  final ValueChanged<Player> onEditPosition;
  final void Function(int, int) onReorder;

  const _SubsDropZone({
    required this.substitutes,
    required this.positionOverrides,
    required this.onDropPlayer,
    required this.onRemove,
    required this.onPromote,
    required this.onEditPosition,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<Player>(
      onWillAcceptWithDetails: (d) => !substitutes.contains(d.data),
      onAcceptWithDetails: (d) => onDropPlayer(d.data),
      builder: (_, candidateData, _) {
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
                      'Drag players here or tap the bench icon on the '
                      'Available tab',
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic),
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
                      positionOverrides: positionOverrides,
                      onEditPosition: onEditPosition,
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

// ─────────────────────────────────────────────────────────────────────────────
// _RosterRowTile — shared tile inside both reorderable lists.
//
// CHANGE (v1.4): Shows a tappable position chip beneath the player name.
// Tapping the chip calls [onEditPosition] to open the override sheet.
// ─────────────────────────────────────────────────────────────────────────────
class _RosterRowTile extends StatelessWidget {
  final Player player;
  final int slotNumber;
  final Color accentColor;
  final Map<String, String> positionOverrides;
  final ValueChanged<Player> onEditPosition;
  final List<Widget> trailingActions;

  const _RosterRowTile({
    super.key,
    required this.player,
    required this.slotNumber,
    required this.accentColor,
    required this.positionOverrides,
    required this.onEditPosition,
    required this.trailingActions,
  });

  @override
  Widget build(BuildContext context) {
    // CHANGE (v1.4): Effective position = override first, then player default.
    final effectivePosition =
        positionOverrides[player.id] ?? player.position;
    final hasOverride = positionOverrides.containsKey(player.id);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
      // CHANGE (v1.4): Position chip — tappable to edit.
      subtitle: GestureDetector(
        onTap: () => onEditPosition(player),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: hasOverride
                    ? accentColor.withValues(alpha: 0.15)
                    : Colors.grey.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: hasOverride
                    ? Border.all(
                        color: accentColor.withValues(alpha: 0.5),
                        width: 1)
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit, size: 10,
                      color: hasOverride ? accentColor : Colors.grey),
                  const SizedBox(width: 3),
                  Text(
                    effectivePosition?.isNotEmpty == true
                        ? effectivePosition!
                        : 'Set position',
                    style: TextStyle(
                      fontSize: 11,
                      color: effectivePosition?.isNotEmpty == true
                          ? (hasOverride ? accentColor : Colors.grey[700])
                          : Colors.grey,
                      fontStyle: effectivePosition == null
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
            if (player.nickname != null) ...[
              const SizedBox(width: 4),
              Text(
                '"${player.nickname}"',
                style: const TextStyle(
                    fontStyle: FontStyle.italic, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: trailingActions,
      ),
    );
  }
}