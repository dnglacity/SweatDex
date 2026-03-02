import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/match.dart';
import '../services/player_service.dart';
import 'game_roster_screen.dart';

// =============================================================================
// match_view_screen.dart  (AOD v1.13)
//
// Full-screen view for a single match. Opened when the user taps a match card
// in MatchesScreen. The top-right overflow menu includes "Match Settings" and,
// for coaches/owners, "Create Invite" to share a 6-character match invite code.
// A clipboard icon (coaches only) opens the Select Roster picker.
// =============================================================================

enum _MatchMenuItem { settings, createInvite }

/// Lightweight roster entry used by the Select Roster picker.
class _RosterEntry {
  final String id;
  final String title;
  final String? gameDate;
  final int starterSlots;

  const _RosterEntry({
    required this.id,
    required this.title,
    this.gameDate,
    required this.starterSlots,
  });

  factory _RosterEntry.fromMap(Map<String, dynamic> m) => _RosterEntry(
        id: m['id'] as String,
        title: m['title'] as String,
        gameDate: m['game_date'] as String?,
        starterSlots: (m['starter_slots'] as int?) ?? 5,
      );
}

class MatchViewScreen extends StatefulWidget {
  final Match match;
  final bool isCoach;

  const MatchViewScreen({
    super.key,
    required this.match,
    this.isCoach = false,
  });

  @override
  State<MatchViewScreen> createState() => _MatchViewScreenState();
}

class _MatchViewScreenState extends State<MatchViewScreen> {
  late Match _match;
  String? _selectedRosterName;

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  static const _shortMonthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static const _dayNames = [
    '', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  @override
  void initState() {
    super.initState();
    _match = widget.match;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isPast = _match.date.isBefore(DateTime.now());

    return Scaffold(
        appBar: AppBar(
          title: Text(_match.title, overflow: TextOverflow.ellipsis),
          leading: BackButton(
            onPressed: () => Navigator.of(context).pop(_match),
          ),
          actions: [
            if (widget.isCoach)
              IconButton(
                icon: const Icon(Icons.assignment_outlined),
                tooltip: 'Select Roster',
                onPressed: () => _showSelectRosterSheet(context),
              ),
            PopupMenuButton<_MatchMenuItem>(
              onSelected: (item) {
                if (item == _MatchMenuItem.settings) {
                  _showMatchSettings(context);
                } else if (item == _MatchMenuItem.createInvite) {
                  _showMatchInviteDialog(context);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _MatchMenuItem.settings,
                  child: Row(
                    children: [
                      Icon(Icons.settings_outlined),
                      SizedBox(width: 12),
                      Text('Match Settings'),
                    ],
                  ),
                ),
                if (widget.isCoach)
                  const PopupMenuItem(
                    value: _MatchMenuItem.createInvite,
                    child: Row(
                      children: [
                        Icon(Icons.share_outlined),
                        SizedBox(width: 12),
                        Text('Create Invite'),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // ── Status chip ─────────────────────────────────────────────────────
            Align(
              alignment: Alignment.centerLeft,
              child: Chip(
                label: Text(isPast ? 'Past' : 'Upcoming'),
                backgroundColor: isPast
                    ? cs.surfaceContainerHighest
                    : cs.primaryContainer,
                labelStyle: TextStyle(
                  color: isPast ? cs.onSurfaceVariant : cs.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
                side: BorderSide.none,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
            const SizedBox(height: 16),

            // ── Teams ────────────────────────────────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _TeamBlock(
                    label: 'My Team',
                    name: _match.myTeamName,
                    rosterLabel: _selectedRosterName,
                    cs: cs,
                    tt: tt,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'vs.',
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                Expanded(
                  child: _TeamBlock(
                    label: 'Opponent',
                    name: _match.opponentName,
                    // Future: pass opponent's selected roster name here.
                    cs: cs,
                    tt: tt,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),

            // ── Date & time ──────────────────────────────────────────────────────
            _InfoRow(
              icon: Icons.calendar_today_outlined,
              label: 'Date',
              value:
                  '${_dayNames[_match.date.weekday]}, ${_monthNames[_match.date.month - 1]} ${_match.date.day}, ${_match.date.year}',
              cs: cs,
              tt: tt,
            ),
            const SizedBox(height: 14),

            // ── Location ─────────────────────────────────────────────────────────
            _InfoRow(
              icon: _match.isHome ? Icons.home_outlined : Icons.directions_bus_outlined,
              label: 'Location',
              value: _match.isHome ? 'Home' : 'Away',
              cs: cs,
              tt: tt,
            ),

            // ── Notes ────────────────────────────────────────────────────────────
            if (_match.notes.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              Text(
                'Notes',
                style: tt.labelLarge?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _match.notes,
                style: tt.bodyMedium?.copyWith(
                  color: cs.onSurface,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
    );
  }

  // ── Select Roster ────────────────────────────────────────────────────────

  Future<void> _showSelectRosterSheet(BuildContext context) async {
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SelectRosterSheet(
        teamId: _match.teamId,
        teamName: _match.myTeamName,
      ),
    );
    if (mounted) setState(() => _selectedRosterName = name ?? _selectedRosterName);
  }

  // ── Match Invite ─────────────────────────────────────────────────────────

  void _showMatchInviteDialog(BuildContext context) {
    String? code;
    DateTime? expiresAt;
    String? errorMsg;
    bool loading = true;
    bool revoking = false;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            if (loading && code == null && errorMsg == null) {
              PlayerService()
                  .getOrCreateMatchInvite(_match.id)
                  .then((data) {
                if (!ctx.mounted) return;
                setDialogState(() {
                  code = data['code'] as String;
                  expiresAt = data['expires_at'] as DateTime;
                  loading = false;
                });
              }).catchError((e) {
                if (!ctx.mounted) return;
                setDialogState(() {
                  errorMsg = e.toString().replaceFirst('Exception: ', '');
                  loading = false;
                });
              });
            }

            String formatExpiry(DateTime dt) {
              final diff = dt.difference(DateTime.now());
              if (diff.inMinutes < 1) return 'Expiring soon';
              if (diff.inHours < 1) return 'Expires in ${diff.inMinutes}m';
              return 'Expires in ${diff.inHours}h ${diff.inMinutes.remainder(60)}m';
            }

            return AlertDialog(
              title: const Text('Match Invite Code'),
              content: SizedBox(
                width: 280,
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : errorMsg != null
                        ? Text(errorMsg!,
                            style: const TextStyle(color: Colors.red))
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Share this code with the opposing coach or owner so they can add this match to their schedule.',
                                style: TextStyle(fontSize: 13),
                              ),
                              const SizedBox(height: 20),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24, vertical: 14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1A3A6B),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  code!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 8,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                formatExpiry(expiresAt!),
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[600]),
                              ),
                              const SizedBox(height: 20),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.copy, size: 18),
                                  label: const Text('Copy Code'),
                                  onPressed: () {
                                    Clipboard.setData(
                                        ClipboardData(text: code!));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text(
                                              'Match invite code copied!')),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  icon: revoking
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const Icon(Icons.block, size: 18),
                                  label: Text(
                                      revoking ? 'Ending...' : 'End Invite'),
                                  style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red),
                                  onPressed: revoking
                                      ? null
                                      : () async {
                                          setDialogState(
                                              () => revoking = true);
                                          final messenger =
                                              ScaffoldMessenger.of(context);
                                          try {
                                            await PlayerService()
                                                .revokeMatchInvite(_match.id);
                                            if (ctx.mounted) {
                                              Navigator.of(ctx).pop();
                                              messenger.showSnackBar(
                                                const SnackBar(
                                                    content: Text(
                                                        'Match invite ended.')),
                                              );
                                            }
                                          } catch (e) {
                                            setDialogState(() {
                                              errorMsg = e
                                                  .toString()
                                                  .replaceFirst(
                                                      'Exception: ', '');
                                              revoking = false;
                                            });
                                          }
                                        },
                                ),
                              ),
                            ],
                          ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showMatchSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MatchSettingsSheet(
        onEdit: () => _openEditSheet(context),
        onDelete: () => _confirmDelete(context),
      ),
    );
  }

  // ── Edit match ──────────────────────────────────────────────────────────────

  void _openEditSheet(BuildContext context) {
    final formKey = GlobalKey<FormState>();
    final opponentCtrl = TextEditingController(text: _match.opponentName);
    final myTeamCtrl = TextEditingController(text: _match.myTeamName);
    final notesCtrl = TextEditingController(text: _match.notes);
    DateTime selectedDate = _match.date;
    bool isHome = _match.isHome;
    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Handle
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        'Edit Match',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 20),

                      // ── Teams row ──────────────────────────────────────────
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: myTeamCtrl,
                              decoration: const InputDecoration(
                                labelText: 'My Team *',
                                border: OutlineInputBorder(),
                              ),
                              textCapitalization: TextCapitalization.words,
                              validator: (v) =>
                                  (v == null || v.trim().isEmpty) ? 'Required' : null,
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Text('vs.', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                          Expanded(
                            child: TextFormField(
                              controller: opponentCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Opponent *',
                                border: OutlineInputBorder(),
                              ),
                              textCapitalization: TextCapitalization.words,
                              validator: (v) =>
                                  (v == null || v.trim().isEmpty) ? 'Required' : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // ── Date ──────────────────────────────────────────────
                      InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: selectedDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2040),
                          );
                          if (picked != null) {
                            setSheetState(() => selectedDate = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Date *',
                            border: OutlineInputBorder(),
                            suffixIcon: Icon(Icons.calendar_today, size: 18),
                          ),
                          child: Text(
                            '${_shortMonthNames[selectedDate.month - 1]} ${selectedDate.day}, ${selectedDate.year}',
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── Home / Away ────────────────────────────────────────
                      Row(
                        children: [
                          const Text('Location:',
                              style: TextStyle(fontWeight: FontWeight.w500)),
                          const SizedBox(width: 12),
                          ChoiceChip(
                            label: const Text('Home'),
                            selected: isHome,
                            onSelected: (_) => setSheetState(() => isHome = true),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Away'),
                            selected: !isHome,
                            onSelected: (_) => setSheetState(() => isHome = false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // ── Notes ─────────────────────────────────────────────
                      TextFormField(
                        controller: notesCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Notes',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        maxLines: 3,
                        textCapitalization: TextCapitalization.sentences,
                      ),
                      const SizedBox(height: 24),

                      // ── Save ──────────────────────────────────────────────
                      FilledButton.icon(
                        onPressed: isSaving
                            ? null
                            : () async {
                                if (!formKey.currentState!.validate()) return;
                                setSheetState(() => isSaving = true);
                                try {
                                  await PlayerService().updateMatch(
                                    matchId: _match.id,
                                    opponentName: opponentCtrl.text.trim(),
                                    myTeamName: myTeamCtrl.text.trim(),
                                    matchDate: selectedDate,
                                    isHome: isHome,
                                    notes: notesCtrl.text.trim(),
                                  );
                                  final updated = _match.copyWith(
                                    myTeamName: myTeamCtrl.text.trim(),
                                    opponentName: opponentCtrl.text.trim(),
                                    date: selectedDate,
                                    isHome: isHome,
                                    notes: notesCtrl.text.trim(),
                                  );
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (mounted) setState(() => _match = updated);
                                } catch (e) {
                                  setSheetState(() => isSaving = false);
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(content: Text('$e')),
                                    );
                                  }
                                }
                              },
                        icon: isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.check),
                        label: const Text('Save Changes'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ── Delete match ────────────────────────────────────────────────────────────

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Match'),
        content: Text(
          'Are you sure you want to delete "${_match.title}"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () async {
              Navigator.pop(ctx); // close dialog
              final nav = Navigator.of(context);
              final messenger = ScaffoldMessenger.of(context);
              try {
                await PlayerService().deleteMatch(_match.id);
                if (mounted) nav.pop(null); // null signals deletion to parent
              } catch (e) {
                if (mounted) {
                  messenger.showSnackBar(SnackBar(content: Text('$e')));
                }
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// ── Supporting widgets ────────────────────────────────────────────────────────

class _TeamBlock extends StatelessWidget {
  final String label;
  final String name;
  final String? rosterLabel;
  final ColorScheme cs;
  final TextTheme tt;

  const _TeamBlock({
    required this.label,
    required this.name,
    this.rosterLabel,
    required this.cs,
    required this.tt,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          style: tt.labelSmall?.copyWith(
            color: cs.onSurface.withValues(alpha: 0.5),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          name,
          textAlign: TextAlign.center,
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (rosterLabel != null) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.assignment_outlined,
                  size: 12, color: cs.onSurface.withValues(alpha: 0.45)),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  rosterLabel!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.55),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final ColorScheme cs;
  final TextTheme tt;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.cs,
    required this.tt,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: cs.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: tt.labelSmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.5),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 2),
              Text(value, style: tt.bodyLarge),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Select Roster Sheet ───────────────────────────────────────────────────────
//
// Shows the team's game rosters via a Realtime stream.  The user taps a roster
// to select it (green check), can tap "+" to create a new one, and taps
// "Confirm" to close with the selection.

class _SelectRosterSheet extends StatefulWidget {
  final String teamId;
  final String teamName;

  const _SelectRosterSheet({
    required this.teamId,
    required this.teamName,
  });

  @override
  State<_SelectRosterSheet> createState() => _SelectRosterSheetState();
}

class _SelectRosterSheetState extends State<_SelectRosterSheet> {
  final _service = PlayerService();

  List<_RosterEntry> _rosters = [];
  bool _loading = true;
  String? _selectedId;

  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _service.getGameRosterStream(widget.teamId).listen(
      (rows) {
        if (mounted) {
          setState(() {
            _rosters = rows.map(_RosterEntry.fromMap).toList();
            _loading = false;
          });
        }
      },
      onError: (_) {
        if (mounted) setState(() => _loading = false);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // ── Create new roster ─────────────────────────────────────────────────────

  Future<void> _showCreateDialog() async {
    final titleCtrl = TextEditingController(text: '${widget.teamName} vs. ');
    final starterCtrl = TextEditingController(text: '5');
    final formKey = GlobalKey<FormState>();
    bool submitted = false;
    int starterSlots = 5;

    final result = await showDialog<({String title, int starterSlots})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: const Text('New Game Roster'),
            content: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: titleCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Roster Title *',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.assignment),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    Text('Starting Roster Size',
                        style: Theme.of(ctx).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: starterSlots > 1
                              ? () => setLocal(() {
                                    starterSlots--;
                                    starterCtrl.text = '$starterSlots';
                                  })
                              : null,
                        ),
                        Expanded(
                          child: TextFormField(
                            controller: starterCtrl,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 12),
                            ),
                            onChanged: (v) {
                              final p = int.tryParse(v);
                              if (p != null && p >= 1 && p <= 50) {
                                setLocal(() => starterSlots = p);
                              }
                            },
                            validator: (v) {
                              final p = int.tryParse(v ?? '');
                              return (p == null || p < 1 || p > 50)
                                  ? '1–50'
                                  : null;
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: starterSlots < 50
                              ? () => setLocal(() {
                                    starterSlots++;
                                    starterCtrl.text = '$starterSlots';
                                  })
                              : null,
                        ),
                      ],
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
                    Navigator.pop(ctx, (
                      title: titleCtrl.text.trim(),
                      starterSlots:
                          (int.tryParse(starterCtrl.text) ?? 5).clamp(1, 50),
                    ));
                  }
                },
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      titleCtrl.dispose();
      starterCtrl.dispose();
    });

    if (result != null && mounted) {
      try {
        final newId = await _service.createGameRoster(
          teamId: widget.teamId,
          title: result.title,
          gameDate: null,
          starterSlots: result.starterSlots,
        );
        // Open the new roster immediately.
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GameRosterScreen(
                teamId: widget.teamId,
                teamName: widget.teamName,
                rosterTitle: result.title,
                gameDate: null,
                starterSlots: result.starterSlots,
                rosterId: newId,
                onCancel: null,
              ),
            ),
          );
          // Auto-select the newly created roster.
          if (mounted) setState(() => _selectedId = newId);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (ctx, scrollCtrl) {
        return Column(
          children: [
            // ── Handle ──────────────────────────────────────────────────────
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Header row ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Select Roster',
                      style: tt.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'New Game Roster',
                    onPressed: _showCreateDialog,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // ── Roster list ─────────────────────────────────────────────────
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rosters.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.assignment,
                                  size: 56, color: Colors.grey[400]),
                              const SizedBox(height: 12),
                              const Text('No game rosters yet'),
                              const SizedBox(height: 8),
                              TextButton.icon(
                                icon: const Icon(Icons.add),
                                label: const Text('Create one'),
                                onPressed: _showCreateDialog,
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: scrollCtrl,
                          itemCount: _rosters.length,
                          itemBuilder: (_, i) {
                            final r = _rosters[i];
                            final selected = r.id == _selectedId;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: cs.primaryContainer,
                                child: Icon(Icons.assignment,
                                    color: cs.primary),
                              ),
                              title: Text(r.title,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              subtitle: Text(r.gameDate != null
                                  ? '${r.gameDate} • ${r.starterSlots} starters'
                                  : '${r.starterSlots} starters'),
                              trailing: selected
                                  ? const Icon(Icons.check_circle,
                                      color: Colors.green)
                                  : null,
                              onTap: () => setState(
                                  () => _selectedId = selected ? null : r.id),
                            );
                          },
                        ),
            ),

            // ── Confirm button ──────────────────────────────────────────────
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () {
                      final name = _selectedId == null
                          ? null
                          : _rosters
                              .firstWhere((r) => r.id == _selectedId)
                              .title;
                      Navigator.of(context).pop(name);
                    },
                    child: const Text('Confirm'),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MatchSettingsSheet extends StatelessWidget {
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MatchSettingsSheet({required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Match Settings',
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit Match'),
              onTap: () {
                Navigator.pop(context);
                onEdit();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: cs.error),
              title: Text('Delete Match', style: TextStyle(color: cs.error)),
              onTap: () {
                Navigator.pop(context);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}
