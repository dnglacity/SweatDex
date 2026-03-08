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
import '../services/auth_service.dart';
import '../services/player_service.dart';
import '../utils/ui_helpers.dart';
import '../widgets/error_dialog.dart';
import '../widgets/date_input_field.dart';
import 'account_settings_screen.dart';
import 'match_format_screen.dart';

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
  final AuthService _authService = AuthService();

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

  // Active match format template (null = no format applied).
  MatchFormatTemplate? _activeFormat;

  // Format slot assignments: key = "$sectionIdx-$positionIdx", value = Player.
  final Map<String, Player> _formatSlots = {};

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

          // Restore active match format if one was saved with this roster.
          MatchFormatTemplate? restoredFormat;
          final savedFormatId =
              rosterData['match_format_template_id'] as String?;
          if (savedFormatId != null && savedFormatId.isNotEmpty) {
            final row = await _playerService
                .getMatchFormatTemplateById(savedFormatId);
            if (row != null) {
              restoredFormat = MatchFormatTemplate.fromMap(row);
            }
          }

          // Restore format slot assignments (key = "$sectionIdx-$positionIdx").
          final savedFormatSlots =
              rosterData['format_slots'] as Map<String, dynamic>?;
          if (savedFormatSlots != null && savedFormatSlots.isNotEmpty) {
            for (final entry in savedFormatSlots.entries) {
              final playerId = entry.value as String?;
              if (playerId != null && playerMap.containsKey(playerId)) {
                _formatSlots[entry.key] = playerMap[playerId]!;
              }
            }
          }

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
            if (restoredFormat != null) {
              _activeFormat = restoredFormat;
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
        showInfoSnackBar(context, 'Error loading players: $e');
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
    if (_substitutes.any((s) => s.id == player.id)) {
      showInfoSnackBar(context, 'Player is already on the bench. Remove them first.');
      return;
    }
    if (_starters.length >= _starterSlots) {
      showInfoSnackBar(context, 'Lineup full ($_starterSlots spots). Adjust or bench a starter.');
      return;
    }
    setState(() => _starters.add(player));
  }

  void _addToSubs(Player player) {
    if (_starters.any((s) => s.id == player.id)) {
      showInfoSnackBar(context, 'Player is already in the starting lineup. Remove them first.');
      return;
    }
    setState(() => _substitutes.add(player));
  }

  void _removeFromStarters(Player p) => setState(() => _starters.remove(p));
  void _removeFromSubs(Player p) => setState(() => _substitutes.remove(p));

  void _promoteSubToStarter(Player player) {
    if (_starters.length >= _starterSlots) {
      showInfoSnackBar(context, 'Starting lineup is full.');
      return;
    }
    setState(() {
      // Remove ALL occurrences of this player from subs (handles duplicates).
      _substitutes.removeWhere((s) => s.id == player.id);
      _starters.add(player);
    });
  }

  void _demoteStarterToSub(Player player) {
    setState(() {
      // Remove ALL occurrences of this player from starters (handles duplicates).
      _starters.removeWhere((s) => s.id == player.id);
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
          matchFormatTemplateId: _activeFormat?.id,
          formatSlots: _formatSlots.isEmpty
              ? null
              : {for (final e in _formatSlots.entries) e.key: e.value.id},
        );

        if (mounted) {
          showSuccessSnackBar(context, 'Roster saved!');
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

  // ── Logout ─────────────────────────────────────────────────────────────────

  Future<void> _performLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    _playerService.clearCache();
    await _authService.signOut();
    if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
  }

  // ── Match Format ──────────────────────────────────────────────────────────

  Future<void> _openMatchFormatPicker() async {
    final selected = await showModalBottomSheet<MatchFormatTemplate>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MatchFormatPickerSheet(teamId: widget.teamId),
    );
    if (selected != null && mounted) {
      setState(() {
        _activeFormat = selected;
        _formatSlots.clear();
      });
      // Switch to the Roster tab so the format view is immediately visible.
      _tabController.animateTo(1);
    }
  }

  /// Shows a bottom sheet for the Match Format overflow menu option.
  /// If a format is active, displays its name with a Remove button.
  /// If no format is active, shows an Add button that opens the picker.
  Future<void> _showMatchFormatOptions() async {
    if (_activeFormat == null) {
      // No format — go straight to picker.
      await _openMatchFormatPicker();
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Match Format',
              style: Theme.of(ctx)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.format_list_bulleted, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _activeFormat!.name,
                    style: Theme.of(ctx).textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _activeFormat = null;
                      _formatSlots.clear();
                    });
                    Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  label: const Text('Remove'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
            icon: const Icon(Icons.more_vert),
            tooltip: 'More options',
            onSelected: (v) async {
              if (v == 'slots') {
                await _showSlotDialog();
              } else if (v == 'date') {
                await _showDateDialog();
              } else if (v == 'matchFormat') {
                await _showMatchFormatOptions();
              } else if (v == 'accountSettings') {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AccountSettingsScreen()),
                );
              } else if (v == 'logout') {
                await _performLogout();
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
              PopupMenuItem(
                value: 'matchFormat',
                child: Row(children: [
                  Icon(Icons.format_list_bulleted, size: 20),
                  SizedBox(width: 12),
                  Text('Match Format'),
                ]),
              ),
              PopupMenuDivider(),
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
                  onEditPosition: _editPositionOverride,
                  activeFormat: _activeFormat,
                  formatSlots: _formatSlots,
                  onFormatSlotChanged: (key, player) {
                    setState(() {
                      if (player == null) {
                        _formatSlots.remove(key);
                      } else {
                        _formatSlots[key] = player;
                      }
                    });
                  },
                ),
              ],
            ),
      bottomNavigationBar: widget.onCancel != null
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: widget.onCancel,
                      icon: const Icon(Icons.close),
                      label: const Text('Cancel Roster'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                    ),
                  ],
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
  final ValueChanged<Player> onEditPosition;
  final MatchFormatTemplate? activeFormat;
  final Map<String, Player> formatSlots;
  final void Function(String key, Player? player) onFormatSlotChanged;

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
    required this.activeFormat,
    required this.formatSlots,
    required this.onFormatSlotChanged,
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

    if (widget.activeFormat != null) {
      return _buildFormatLayout(context);
    }

    final theme = Theme.of(context);

    // Count how many times each player id appears across starters + subs.
    final appearanceCounts = <String, int>{};
    for (final p in [...widget.starters, ...widget.substitutes]) {
      appearanceCounts[p.id] = (appearanceCounts[p.id] ?? 0) + 1;
    }

    // Split into two fixed halves so both zones are always visible on screen —
    // a SingleChildScrollView would scroll the subs zone out of reach during drag.
    return Column(
      children: [
        // ── Starting Lineup (top half) ─────────────────────────────────────
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
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
                Expanded(
                  child: _StarterDropZone(
                    starters: widget.starters,
                    substitutes: widget.substitutes,
                    starterSlots: widget.starterSlots,
                    positionOverrides: widget.positionOverrides,
                    appearanceCounts: appearanceCounts,
                    onDropPlayer: (player) {
                      if (widget.substitutes.any((s) => s.id == player.id)) {
                        widget.onPromote(player);
                      } else {
                        widget.onDropToStarters(player);
                      }
                    },
                    onRemove: widget.onRemoveStarter,
                    onSendToBench: widget.onSendToBench,
                    onEditPosition: widget.onEditPosition,
                    onReorder: widget.onReorderStarters,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1),
        // ── Substitutes Bench (bottom half) ───────────────────────────────
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionHeader(
                  context: context,
                  label: 'Substitutes Bench',
                  count: widget.substitutes.length,
                  max: null,
                  color: theme.colorScheme.secondary,
                  icon: Icons.airline_seat_recline_normal,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _SubsDropZone(
                    substitutes: widget.substitutes,
                    starters: widget.starters,
                    positionOverrides: widget.positionOverrides,
                    appearanceCounts: appearanceCounts,
                    onDropPlayer: (player) {
                      if (widget.starters.any((s) => s.id == player.id)) {
                        widget.onSendToBench(player);
                      } else {
                        widget.onDropToSubs(player);
                      }
                    },
                    onRemove: widget.onRemoveSub,
                    onPromote: widget.onPromote,
                    onEditPosition: widget.onEditPosition,
                    onReorder: widget.onReorderSubs,
                  ),
                ),
              ],
            ),
          ),
        ),
        // ── Return to Available drop zone ──────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: DragTarget<Player>(
            onWillAcceptWithDetails: (d) =>
                widget.starters.any((s) => s.id == d.data.id) ||
                widget.substitutes.any((s) => s.id == d.data.id),
            onAcceptWithDetails: (d) {
              if (widget.starters.any((s) => s.id == d.data.id)) {
                widget.onRemoveStarter(d.data);
              } else {
                widget.onRemoveSub(d.data);
              }
            },
            builder: (_, candidateData, __) {
              final isHovering = candidateData.isNotEmpty;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 48,
                decoration: BoxDecoration(
                  color: isHovering
                      ? Colors.orange.withValues(alpha: 0.12)
                      : Colors.transparent,
                  border: Border.all(
                    color: isHovering
                        ? Colors.orange
                        : Colors.grey.withValues(alpha: 0.35),
                    width: isHovering ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.undo,
                        size: 16,
                        color: isHovering ? Colors.orange : Colors.grey[500]),
                    const SizedBox(width: 6),
                    Text(
                      'Drop here to return to Available',
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: isHovering ? Colors.orange : Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Format-based split layout ─────────────────────────────────────────────
  // Shows sections + empty position slots on the left, and the
  // starters/substitutes list on the right.  Tapping a slot picks a player
  // from the right-side list; tapping an occupied slot clears it.
  Widget _buildFormatLayout(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final format = widget.activeFormat!;

    // Count how many format slots each player id is assigned to.
    final formatSlotCounts = <String, int>{};
    for (final p in widget.formatSlots.values) {
      formatSlotCounts[p.id] = (formatSlotCounts[p.id] ?? 0) + 1;
    }
    final assignedIds = formatSlotCounts.keys.toSet();

    // All roster players are assignable — already-assigned players can be
    // dragged to additional slots (duplicates allowed in the format layout).
    final assignable = [
      ...widget.starters,
      ...widget.substitutes,
    ];

    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Left: sections + position slots ─────────────────────────
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
            itemCount: format.sections.length,
            itemBuilder: (ctx, sIdx) {
              final section = format.sections[sIdx];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Section header
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      section.title,
                      style: theme.textTheme.labelLarge?.copyWith(
                          color: cs.onPrimary,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Position slots
                  for (int pIdx = 0;
                      pIdx < section.positionCount;
                      pIdx++) ...[
                    _FormatPositionSlot(
                      slotKey: '$sIdx-$pIdx',
                      positionNumber: pIdx + 1,
                      assignedPlayer:
                          widget.formatSlots['$sIdx-$pIdx'],
                      assignablePlayers: assignable,
                      onAssign: (p) =>
                          widget.onFormatSlotChanged('$sIdx-$pIdx', p),
                      onClear: () =>
                          widget.onFormatSlotChanged('$sIdx-$pIdx', null),
                    ),
                    const SizedBox(height: 4),
                  ],
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
        ),

        // Divider
        VerticalDivider(width: 1, color: cs.outlineVariant),

        // ── Right: starters / substitutes list ────────────────────────────
        // Split into two DragTarget halves so players can be promoted/demoted
        // by dragging between sections even while a format is active.
        Expanded(
          child: Column(
            children: [
              // Starters section — drop a sub here to promote them.
              Expanded(
                child: DragTarget<Player>(
                  onWillAcceptWithDetails: (d) =>
                      widget.substitutes.any((s) => s.id == d.data.id),
                  onAcceptWithDetails: (d) => widget.onPromote(d.data),
                  builder: (_, candidateData, __) {
                    final isHovering = candidateData.isNotEmpty;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.fromLTRB(6, 12, 12, 4),
                      decoration: BoxDecoration(
                        color: isHovering
                            ? cs.primary.withValues(alpha: 0.07)
                            : cs.surface,
                        border: Border.all(
                          color: isHovering
                              ? cs.primary
                              : cs.outline.withValues(alpha: 0.12),
                          width: isHovering ? 2 : 1,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                            child: _formatSideHeader(
                                context, 'Starters', Icons.star, cs.primary),
                          ),
                          Expanded(
                            child: widget.starters.isEmpty
                                ? Center(child: _emptyHint('No starters assigned'))
                                : ListView(
                                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                    children: [
                                      for (final p in widget.starters)
                                        _FormatPlayerTile(
                                          player: p,
                                          isAssigned: assignedIds.contains(p.id),
                                          slotCount: formatSlotCounts[p.id] ?? 0,
                                        ),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // Substitutes section — drop a starter here to bench them.
              Expanded(
                child: DragTarget<Player>(
                  onWillAcceptWithDetails: (d) =>
                      widget.starters.any((s) => s.id == d.data.id),
                  onAcceptWithDetails: (d) => widget.onSendToBench(d.data),
                  builder: (_, candidateData, __) {
                    final isHovering = candidateData.isNotEmpty;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.fromLTRB(6, 4, 12, 12),
                      decoration: BoxDecoration(
                        color: isHovering
                            ? cs.secondary.withValues(alpha: 0.07)
                            : cs.surface,
                        border: Border.all(
                          color: isHovering
                              ? cs.secondary
                              : cs.outline.withValues(alpha: 0.12),
                          width: isHovering ? 2 : 1,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                            child: _formatSideHeader(
                                context,
                                'Substitutes',
                                Icons.airline_seat_recline_normal,
                                cs.secondary),
                          ),
                          Expanded(
                            child: widget.substitutes.isEmpty
                                ? Center(child: _emptyHint('No substitutes assigned'))
                                : ListView(
                                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                    children: [
                                      for (final p in widget.substitutes)
                                        _FormatPlayerTile(
                                          player: p,
                                          isAssigned: assignedIds.contains(p.id),
                                          slotCount: formatSlotCounts[p.id] ?? 0,
                                        ),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    ),
        ),
        // ── Return to Available drop zone ──────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: DragTarget<Player>(
            onWillAcceptWithDetails: (d) =>
                widget.starters.any((s) => s.id == d.data.id) ||
                widget.substitutes.any((s) => s.id == d.data.id),
            onAcceptWithDetails: (d) {
              if (widget.starters.any((s) => s.id == d.data.id)) {
                widget.onRemoveStarter(d.data);
              } else {
                widget.onRemoveSub(d.data);
              }
            },
            builder: (_, candidateData, __) {
              final isHovering = candidateData.isNotEmpty;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 48,
                decoration: BoxDecoration(
                  color: isHovering
                      ? Colors.orange.withValues(alpha: 0.12)
                      : Colors.transparent,
                  border: Border.all(
                    color: isHovering
                        ? Colors.orange
                        : Colors.grey.withValues(alpha: 0.35),
                    width: isHovering ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.undo,
                        size: 16,
                        color: isHovering ? Colors.orange : Colors.grey[500]),
                    const SizedBox(width: 6),
                    Text(
                      'Drop here to return to Available',
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: isHovering ? Colors.orange : Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _formatSideHeader(
      BuildContext context, String label, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  )),
        ],
      ),
    );
  }

  Widget _emptyHint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: Colors.grey[500])),
      );

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
// _FormatPositionSlot — one position slot in the format layout (left side).
// Shows empty (dashed) or the assigned player's name.
// Tapping an empty slot opens a picker; tapping an occupied slot clears it.
// ─────────────────────────────────────────────────────────────────────────────
class _FormatPositionSlot extends StatelessWidget {
  final String slotKey;
  final int positionNumber;
  final Player? assignedPlayer;
  final List<Player> assignablePlayers;
  final ValueChanged<Player> onAssign;
  final VoidCallback onClear;

  const _FormatPositionSlot({
    required this.slotKey,
    required this.positionNumber,
    required this.assignedPlayer,
    required this.assignablePlayers,
    required this.onAssign,
    required this.onClear,
  });

  Future<void> _pick(BuildContext context) async {
    if (assignedPlayer != null) {
      onClear();
      return;
    }
    if (assignablePlayers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No unassigned players. Add players in the Available tab.')),
      );
      return;
    }
    final picked = await showModalBottomSheet<Player>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text('Assign to Position $positionNumber',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: assignablePlayers.length,
                itemBuilder: (_, i) {
                  final p = assignablePlayers[i];
                  return ListTile(
                    leading: CircleAvatar(child: Text(p.name[0])),
                    title: Text(p.name),
                    subtitle: p.position != null
                        ? Text(p.position!)
                        : null,
                    onTap: () => Navigator.pop(ctx, p),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null) onAssign(picked);
  }

  Widget _buildSlot(BuildContext context, {bool isHovering = false}) {
    final cs = Theme.of(context).colorScheme;
    final isEmpty = assignedPlayer == null;

    return GestureDetector(
      onTap: () => _pick(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 40,
        decoration: BoxDecoration(
          color: isHovering
              ? cs.primary.withValues(alpha: 0.12)
              : isEmpty
                  ? cs.surface
                  : cs.primaryContainer.withValues(alpha: 0.6),
          border: Border.all(
            color: isHovering
                ? cs.primary
                : isEmpty
                    ? cs.outline.withValues(alpha: 0.5)
                    : cs.primary,
            width: isHovering ? 2 : isEmpty ? 1 : 1.5,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              alignment: Alignment.center,
              child: Text(
                '$positionNumber',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurfaceVariant),
              ),
            ),
            const VerticalDivider(width: 1),
            const SizedBox(width: 8),
            Expanded(
              child: isEmpty
                  ? Text(
                      isHovering ? 'Drop here' : 'Empty',
                      style: TextStyle(
                          fontSize: 12,
                          color: isHovering
                              ? cs.primary
                              : cs.onSurface.withValues(alpha: 0.4),
                          fontStyle: FontStyle.italic),
                    )
                  : Text(
                      assignedPlayer!.name,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            if (!isEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.close,
                    size: 14,
                    color: cs.onSurface.withValues(alpha: 0.5)),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<Player>(
      onWillAcceptWithDetails: (d) =>
          assignedPlayer == null && assignablePlayers.contains(d.data),
      onAcceptWithDetails: (d) => onAssign(d.data),
      builder: (context, candidateData, rejectedData) =>
          _buildSlot(context, isHovering: candidateData.isNotEmpty),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _FormatPlayerTile — player tile in the right-side list of the format layout.
// Dimmed when already assigned to a slot.
// ─────────────────────────────────────────────────────────────────────────────
class _FormatPlayerTile extends StatelessWidget {
  final Player player;
  final bool isAssigned;
  final int slotCount;

  const _FormatPlayerTile({
    required this.player,
    required this.isAssigned,
    required this.slotCount,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isAssigned
              ? cs.surfaceContainerHighest.withValues(alpha: 0.65)
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: isAssigned
                  ? cs.primary.withValues(alpha: 0.55)
                  : cs.primary,
              child: Text(
                player.name[0],
                style: TextStyle(
                    fontSize: 11,
                    color: isAssigned
                        ? cs.onPrimary.withValues(alpha: 0.75)
                        : cs.onPrimary),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      player.name,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isAssigned
                              ? cs.onSurface.withValues(alpha: 0.65)
                              : null),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (slotCount > 1) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: 'Assigned to $slotCount positions',
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade700,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                size: 11, color: Colors.white),
                            const SizedBox(width: 2),
                            Text(
                              '$slotCount',
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Always show drag handle; add checkmark alongside it when assigned.
            if (isAssigned)
              Icon(Icons.check_circle,
                  size: 13,
                  color: cs.primary.withValues(alpha: 0.7)),
            const SizedBox(width: 2),
            Icon(Icons.drag_indicator,
                size: 14,
                color: cs.onSurface.withValues(alpha: isAssigned ? 0.45 : 0.3)),
          ],
        ),
      ),
    );

    // Always draggable — allows the same player to be assigned to multiple slots.
    return LongPressDraggable<Player>(
      data: player,
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(player.name,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: cs.onPrimaryContainer)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: tile),
      child: tile,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _MatchFormatPickerSheet — bottom sheet shown when tapping "Match Format".
// Loads saved templates for the team and lets the user pick one.
// ─────────────────────────────────────────────────────────────────────────────
class _MatchFormatPickerSheet extends StatefulWidget {
  final String teamId;

  const _MatchFormatPickerSheet({required this.teamId});

  @override
  State<_MatchFormatPickerSheet> createState() =>
      _MatchFormatPickerSheetState();
}

class _MatchFormatPickerSheetState extends State<_MatchFormatPickerSheet> {
  final _service = PlayerService();
  List<MatchFormatTemplate> _templates = [];
  List<MatchFormatTemplate> _coreTemplates = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final teamRows = _service.getMatchFormatTemplates(widget.teamId);
      final coreRows = _service.getCoreMatchFormatTemplates();
      final results = await Future.wait([teamRows, coreRows]);
      if (mounted) {
        setState(() {
          _templates = results[0].map(MatchFormatTemplate.fromMap).toList();
          _coreTemplates = results[1]
              .map((r) => MatchFormatTemplate.fromMap({...r, 'team_id': ''}))
              .toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _selectCoreTemplate(MatchFormatTemplate core) async {
    // Reuse existing team copy by name if present
    final existing = _templates.where((t) => t.name == core.name).firstOrNull;
    if (existing != null) {
      if (mounted) Navigator.pop(context, existing);
      return;
    }
    // Create team copy
    try {
      final row = await _service.createMatchFormatTemplate(
        teamId: widget.teamId,
        name: core.name,
        sections: core.sections.map((s) => s.toMap()).toList(),
      );
      if (mounted) Navigator.pop(context, MatchFormatTemplate.fromMap(row));
    } catch (e) {
      if (mounted) showInfoSnackBar(context, 'Could not apply template: $e');
    }
  }

  Future<void> _openEdit(MatchFormatTemplate t) async {
    final updated = await showModalBottomSheet<MatchFormatTemplate>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => EditFormatSheet(
            template: t,
            onDeleted: () {
              if (mounted) {
                setState(() => _templates.removeWhere((x) => x.id == t.id));
              }
            },
          ),
    );
    if (updated != null && mounted) {
      setState(() {
        final i = _templates.indexWhere((x) => x.id == updated.id);
        if (i != -1) _templates[i] = updated;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.85,
      builder: (_, scrollCtrl) => Column(
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Row(
              children: [
                Text('Select Match Format',
                    style: tt.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New'),
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              MatchFormatScreen(teamId: widget.teamId)),
                    );
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Error loading formats',
                                style: TextStyle(color: cs.error)),
                            TextButton(
                                onPressed: _load, child: const Text('Retry')),
                          ],
                        ),
                      )
                    : (_templates.isEmpty && _coreTemplates.isEmpty)
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.format_list_bulleted_outlined,
                                    size: 48,
                                    color: cs.onSurface.withValues(alpha: 0.3)),
                                const SizedBox(height: 10),
                                Text('No formats yet',
                                    style: TextStyle(
                                        color: cs.onSurface
                                            .withValues(alpha: 0.5))),
                                const SizedBox(height: 8),
                                FilledButton.icon(
                                  icon: const Icon(Icons.add, size: 16),
                                  label: const Text('Create Format'),
                                  onPressed: () {
                                    Navigator.pop(context);
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => MatchFormatScreen(
                                              teamId: widget.teamId)),
                                    );
                                  },
                                ),
                              ],
                            ),
                          )
                        : ListView(
                            controller: scrollCtrl,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            children: [
                              if (_coreTemplates.isNotEmpty) ...[
                                _SectionHeader(label: '★ Core Library'),
                                ..._coreTemplates.map((t) => Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ListTile(
                                          leading: const Icon(
                                              Icons.public_outlined),
                                          title: Text(t.name,
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w600)),
                                          subtitle: Text(
                                            '${t.sections.length} section${t.sections.length == 1 ? '' : 's'}'
                                            '${t.sport != null && t.sport!.isNotEmpty ? ' · ${t.sport}' : ''}',
                                          ),
                                          trailing: const Icon(
                                              Icons.chevron_right),
                                          onTap: () =>
                                              _selectCoreTemplate(t),
                                        ),
                                        const Divider(height: 1),
                                      ],
                                    )),
                              ],
                              _SectionHeader(label: 'My Formats'),
                              ..._templates.map((t) => Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(
                                        leading: const Icon(
                                            Icons.format_list_bulleted_outlined),
                                        title: Text(t.name,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600)),
                                        subtitle: Text(
                                          '${t.sections.length} section${t.sections.length == 1 ? '' : 's'}',
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(
                                                  Icons.edit_outlined),
                                              tooltip: 'Edit',
                                              onPressed: () => _openEdit(t),
                                            ),
                                            const Icon(Icons.chevron_right),
                                          ],
                                        ),
                                        onTap: () =>
                                            Navigator.pop(context, t),
                                      ),
                                      const Divider(height: 1),
                                    ],
                                  )),
                            ],
                          ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SectionHeader — sticky label used in _MatchFormatPickerSheet
// ─────────────────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: cs.onSurface.withValues(alpha: 0.6),
          letterSpacing: 0.5,
        ),
      ),
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
  final List<Player> substitutes;
  final int starterSlots;
  final Map<String, String> positionOverrides;
  final Map<String, int> appearanceCounts;
  final ValueChanged<Player> onDropPlayer;
  final ValueChanged<Player> onRemove;
  final ValueChanged<Player> onSendToBench;
  final ValueChanged<Player> onEditPosition;
  final void Function(int, int) onReorder;

  const _StarterDropZone({
    required this.starters,
    required this.substitutes,
    required this.starterSlots,
    required this.positionOverrides,
    required this.appearanceCounts,
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
      // Accept if not full. Cross-side (subs) drops are handled as promotions.
      // Same-side drops create a duplicate entry.
      onWillAcceptWithDetails: (d) => !isFull,
      onAcceptWithDetails: (d) => onDropPlayer(d.data),
      builder: (_, candidateData, _) {
        final isHovering = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isHovering
                ? Colors.blue.withValues(alpha: 0.07)
                : theme.colorScheme.surface,
            border: Border.all(
              color: isHovering
                  ? Colors.blue
                  : theme.colorScheme.outline.withValues(alpha: 0.12),
              width: isHovering ? 2.5 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: isHovering
                ? [
                    BoxShadow(
                      color: Colors.blue.withValues(alpha: 0.25),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          // SizedBox.expand fills the Expanded parent so the drop zone is
          // always full-height and reachable by a dragged player.
          child: SizedBox.expand(
            child: starters.isEmpty
                ? Center(
                    child: Text(
                      isFull
                          ? 'Lineup full'
                          : 'Drag players here or tap ★ on the Available tab',
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: starters.length,
                    onReorder: onReorder,
                    itemBuilder: (_, i) {
                      final p = starters[i];
                      return _RosterRowTile(
                        key: ValueKey('starter-$i'),
                        player: p,
                        slotNumber: i + 1,
                        accentColor: theme.colorScheme.primary,
                        positionOverrides: positionOverrides,
                        appearanceCount: appearanceCounts[p.id] ?? 1,
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
  final List<Player> starters;
  final Map<String, String> positionOverrides;
  final Map<String, int> appearanceCounts;
  final ValueChanged<Player> onDropPlayer;
  final ValueChanged<Player> onRemove;
  final ValueChanged<Player> onPromote;
  final ValueChanged<Player> onEditPosition;
  final void Function(int, int) onReorder;

  const _SubsDropZone({
    required this.substitutes,
    required this.starters,
    required this.positionOverrides,
    required this.appearanceCounts,
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
      // Always accept. Cross-side (starters) drops are handled as demotions.
      // Same-side drops create a duplicate entry.
      onWillAcceptWithDetails: (d) => true,
      onAcceptWithDetails: (d) => onDropPlayer(d.data),
      builder: (_, candidateData, _) {
        final isHovering = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isHovering
                ? Colors.blue.withValues(alpha: 0.07)
                : theme.colorScheme.surface,
            border: Border.all(
              color: isHovering
                  ? Colors.blue
                  : theme.colorScheme.outline.withValues(alpha: 0.12),
              width: isHovering ? 2.5 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: isHovering
                ? [
                    BoxShadow(
                      color: Colors.blue.withValues(alpha: 0.25),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: SizedBox.expand(
            child: substitutes.isEmpty
                ? Center(
                    child: Text(
                      'Drag players here or tap the bench icon on the '
                      'Available tab',
                      style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: substitutes.length,
                    onReorder: onReorder,
                    itemBuilder: (_, i) {
                      final p = substitutes[i];
                      return _RosterRowTile(
                        key: ValueKey('sub-$i'),
                        player: p,
                        slotNumber: i + 1,
                        accentColor: theme.colorScheme.secondary,
                        positionOverrides: positionOverrides,
                        appearanceCount: appearanceCounts[p.id] ?? 1,
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
  final int appearanceCount;
  final ValueChanged<Player> onEditPosition;
  final List<Widget> trailingActions;

  const _RosterRowTile({
    super.key,
    required this.player,
    required this.slotNumber,
    required this.accentColor,
    required this.positionOverrides,
    required this.appearanceCount,
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
          // Draggable handle: immediate drag = cross-section move.
          // Long-press anywhere else on the tile = within-section reorder
          // (handled by ReorderableListView's delayed drag recogniser).
          Draggable<Player>(
            data: player,
            feedback: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: accentColor,
                      child: Text(
                        player.jerseyNumber ?? '?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(player.name,
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: accentColor)),
                  ],
                ),
              ),
            ),
            childWhenDragging: const Opacity(
              opacity: 0.3,
              child: Icon(Icons.drag_handle, color: Colors.grey, size: 20),
            ),
            child: const Icon(Icons.drag_handle, color: Colors.grey, size: 20),
          ),
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
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(player.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          if (appearanceCount > 1) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: 'Assigned to $appearanceCount positions',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.amber.shade700,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 12, color: Colors.white),
                    const SizedBox(width: 2),
                    Text(
                      '$appearanceCount',
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
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