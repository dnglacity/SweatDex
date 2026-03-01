import 'package:flutter/material.dart';
import '../models/player.dart';
import '../services/auth_service.dart';
import '../services/player_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// player_self_view_screen.dart  (AOD v1.5)
//
// CHANGE (Notes.txt v1.5 — Unified users):
//   • getMyPlayerOnTeam() now resolves the player via players.user_id directly
//     instead of going through the old player_accounts join table.
//   • No other changes to this screen's UI or logic.
//
// Retained from v1.3:
//   • Read-only view of own player card, current status, and teammates list.
//   • Pull-to-refresh support.
// ─────────────────────────────────────────────────────────────────────────────

class PlayerSelfViewScreen extends StatefulWidget {
  final String teamId;
  final String teamName;

  const PlayerSelfViewScreen({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  @override
  State<PlayerSelfViewScreen> createState() => _PlayerSelfViewScreenState();
}

class _PlayerSelfViewScreenState extends State<PlayerSelfViewScreen> {
  final _playerService = PlayerService();
  final _authService = AuthService();

  /// The player row linked to the current auth account on this team.
  Player? _myPlayer;

  /// All players on the team — used for the teammates list.
  List<Player> _allPlayers = [];

  bool _loading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Log Out')),
        ],
      ),
    );
    if (confirm != true) return;
    _playerService.clearCache();
    await _authService.signOut();
    // Pop back to AuthWrapper's root so its StreamBuilder can render LoginScreen.
    if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      // CHANGE (v1.5): getMyPlayerOnTeam() now uses players.user_id FK
      // instead of the old player_accounts table.
      final myPlayerData =
          await _playerService.getMyPlayerOnTeam(widget.teamId);
      final allPlayers = await _playerService.getPlayers(widget.teamId);

      setState(() {
        _myPlayer = myPlayerData;
        _allPlayers = allPlayers;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.teamName,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const Text('My Team View',
                style:
                    TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'logout') await _performLogout();
            },
            itemBuilder: (_) => const [
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
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? _buildError()
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: _buildContent(theme, cs),
                ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.red),
          const SizedBox(height: 16),
          Text(_errorMessage ?? 'Unknown error'),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme, ColorScheme cs) {
    final teammates = _myPlayer != null
        ? _allPlayers.where((p) => p.id != _myPlayer!.id).toList()
        : _allPlayers;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_myPlayer != null) ...[
          Text('My Profile',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _MyPlayerCard(player: _myPlayer!, cs: cs),
          const SizedBox(height: 24),
          Text('Current Status',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _AttendanceSummaryCard(player: _myPlayer!, cs: cs),
          const SizedBox(height: 24),
        ] else ...[
          // Not yet linked to a player row on this team.
          Card(
            color: cs.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: cs.error),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Your account is not yet linked to a player on this '
                      'team. Ask your coach to link you.',
                      style: TextStyle(color: cs.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],

        // ── Teammates list ────────────────────────────────────────────────
        Row(
          children: [
            Text('Teammates',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${teammates.length}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: cs.primary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (teammates.isEmpty)
          const Center(
              child: Text('No teammates yet.',
                  style: TextStyle(fontStyle: FontStyle.italic)))
        else
          ...teammates.map((p) => _TeammateRow(player: p, cs: cs)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _MyPlayerCard
// ─────────────────────────────────────────────────────────────────────────────
class _MyPlayerCard extends StatelessWidget {
  final Player player;
  final ColorScheme cs;

  const _MyPlayerCard({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: cs.primary,
              child: Text(
                player.displayJersey,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: cs.onPrimary,
                ),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(player.name,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  if (player.nickname != null &&
                      player.nickname!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text('"${player.nickname}"',
                        style: TextStyle(
                            fontStyle: FontStyle.italic,
                            color: Colors.grey[600])),
                  ],
                  if (player.position != null &&
                      player.position!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(player.position!,
                        style: TextStyle(color: Colors.grey[600])),
                  ],
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: player.statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border:
                          Border.all(color: player.statusColor, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(player.statusIcon,
                            size: 14, color: player.statusColor),
                        const SizedBox(width: 4),
                        Text(
                          player.statusLabel,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: player.statusColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AttendanceSummaryCard
// ─────────────────────────────────────────────────────────────────────────────
class _AttendanceSummaryCard extends StatelessWidget {
  final Player player;
  final ColorScheme cs;

  const _AttendanceSummaryCard({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    // [Inference] Currently only the live status is available per the existing
    // data model (no attendance_log table). A future enhancement can add
    // historical tracking.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(player.statusIcon, color: player.statusColor),
                const SizedBox(width: 8),
                Text(
                  "Today's Status: ${player.statusLabel}",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: player.statusColor,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Full attendance history will be available in a future update. '
              'Your coach sets your status during each practice or game.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _TeammateRow — read-only teammate entry (names and jersey only)
// ─────────────────────────────────────────────────────────────────────────────
class _TeammateRow extends StatelessWidget {
  final Player player;
  final ColorScheme cs;

  const _TeammateRow({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: cs.primaryContainer,
          child: Text(
            player.displayJersey,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: cs.onPrimaryContainer,
                fontSize: 12),
          ),
        ),
        title: Text(player.name,
            style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: player.nickname != null
            ? Text('"${player.nickname}"',
                style: const TextStyle(fontStyle: FontStyle.italic))
            : null,
        // Intentionally no trailing actions — read-only view.
      ),
    );
  }
}