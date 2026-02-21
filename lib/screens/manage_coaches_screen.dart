import 'package:flutter/material.dart';
import '../services/player_service.dart';

/// ManageCoachesScreen — view and manage all coaches on a team.
///
/// BUG FIX (Bug 8): When a coach removes themselves, the previous code only
/// called `Navigator.of(context).pop()`, which returned to RosterScreen.
/// RosterScreen then continued trying to stream players for a team the coach
/// no longer has access to, causing RLS errors.
/// Fix: Pop all the way back to the root (TeamSelectionScreen) on self-removal.
class ManageCoachesScreen extends StatefulWidget {
  final String teamId;
  final String teamName;

  const ManageCoachesScreen({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  @override
  State<ManageCoachesScreen> createState() => _ManageCoachesScreenState();
}

class _ManageCoachesScreenState extends State<ManageCoachesScreen> {
  final _playerService = PlayerService();
  late Future<List<Map<String, dynamic>>> _coachesFuture;

  // The current user's coach ID — used to identify the "YOU" badge and
  // self-removal vs. other-removal logic.
  String? _currentCoachId;

  @override
  void initState() {
    super.initState();
    _loadCurrentCoach();
    _refreshCoaches();
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  /// Fetches the current user's coach profile and caches their ID.
  Future<void> _loadCurrentCoach() async {
    try {
      final coach = await _playerService.getCurrentCoach();
      if (mounted) {
        setState(() {
          _currentCoachId = coach?['id'];
        });
      }
    } catch (e) {
      debugPrint('Error loading current coach: $e');
    }
  }

  /// Re-fetches the team's coach list and triggers a rebuild.
  void _refreshCoaches() {
    setState(() {
      _coachesFuture = _playerService.getTeamCoaches(widget.teamId);
    });
  }

  // ── Add coach dialog ──────────────────────────────────────────────────────

  Future<void> _showAddCoachDialog() async {
    final emailController = TextEditingController();
    final roleController = TextEditingController(text: 'Assistant Coach');
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Coach'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Coach email input.
              TextFormField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
                decoration: const InputDecoration(
                  labelText: 'Coach Email',
                  hintText: 'coach@example.com',
                  prefixIcon: Icon(Icons.email),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter an email';
                  }
                  if (!value.contains('@')) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              // Role input.
              TextFormField(
                controller: roleController,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) {
                  if (formKey.currentState!.validate()) {
                    Navigator.pop(context, true);
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Role',
                  hintText: 'e.g., Assistant Coach',
                  prefixIcon: Icon(Icons.badge),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      try {
        await _playerService.addCoachToTeam(
          widget.teamId,
          emailController.text.trim(),
          roleController.text.trim(),
        );
        _refreshCoaches();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Coach added successfully!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString().replaceAll('Exception: ', '')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }

    emailController.dispose();
    roleController.dispose();
  }

  // ── Remove coach ──────────────────────────────────────────────────────────

  /// Confirms removal of a coach, then removes them.
  ///
  /// BUG FIX (Bug 8): When the coach removes themselves, the old code called
  /// `Navigator.of(context).pop()` once — landing back on RosterScreen, which
  /// would then fail all Supabase queries because the user is no longer a
  /// team member (RLS blocks everything).
  ///
  /// Fix: Use `popUntil((route) => route.isFirst)` to return all the way to
  /// TeamSelectionScreen, which gracefully refreshes its team list.
  Future<void> _confirmRemoveCoach(Map<String, dynamic> coach) async {
    final isSelf = coach['id'] == _currentCoachId;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isSelf ? 'Leave Team' : 'Remove Coach'),
        content: Text(
          isSelf
              ? 'Are you sure you want to leave this team?'
              : 'Remove ${coach['name']} from this team?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(isSelf ? 'Leave' : 'Remove'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      try {
        await _playerService.removeCoachFromTeam(
            widget.teamId, coach['id'] as String);

        if (!mounted) return;

        if (isSelf) {
          // FIX (Bug 8): Pop all the way back to TeamSelectionScreen.
          // If we only popped once we'd land on RosterScreen, which would
          // then fail all player-stream queries because RLS no longer
          // recognises us as a team member.
          Navigator.of(context).popUntil((route) => route.isFirst);
          return;
        }

        // Non-self removal: just refresh the coaches list.
        _refreshCoaches();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${coach['name']} removed')),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString().replaceAll('Exception: ', '')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  // ── Transfer ownership dialog ─────────────────────────────────────────────

  Future<void> _showTransferOwnershipDialog(
      List<Map<String, dynamic>> coaches) async {
    // Only non-owner coaches are eligible transfer targets.
    final eligibleCoaches =
        coaches.where((c) => c['is_owner'] != true).toList();

    if (eligibleCoaches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No other coaches to transfer ownership to')),
      );
      return;
    }

    final selectedCoach = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Transfer Ownership'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: eligibleCoaches.map((coach) {
            return ListTile(
              leading: CircleAvatar(
                child: Text((coach['name'] as String)[0].toUpperCase()),
              ),
              title: Text(coach['name'] as String),
              subtitle: Text(coach['role'] as String),
              onTap: () => Navigator.pop(context, coach),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selectedCoach != null && mounted) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm Transfer'),
          content: Text(
            'Transfer team ownership to ${selectedCoach['name']}?\n\n'
            'You will no longer be the owner but will remain on the team.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Transfer'),
            ),
          ],
        ),
      );

      if (confirm == true && mounted) {
        try {
          await _playerService.transferOwnership(
              widget.teamId, selectedCoach['id'] as String);
          _refreshCoaches();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(
                      'Ownership transferred to ${selectedCoach['name']}')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(e.toString().replaceAll('Exception: ', '')),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.teamName} Coaches'),
        centerTitle: true,
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _coachesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

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
                    onPressed: _refreshCoaches,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          final coaches = snapshot.data ?? [];

          // Determine if the current user is the team owner.
          final currentCoach = coaches.firstWhere(
            (c) => c['id'] == _currentCoachId,
            orElse: () => {},
          );
          final isCurrentUserOwner =
              currentCoach.isNotEmpty && currentCoach['is_owner'] == true;

          return Column(
            children: [
              // ── Role banner ───────────────────────────────────────────────
              if (isCurrentUserOwner)
                Card(
                  margin: const EdgeInsets.all(16),
                  color: Colors.amber[50],
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.shield, color: Colors.amber[700]),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'You are the team owner',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'You can manage coaches and transfer ownership',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[700]),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              _showTransferOwnershipDialog(coaches),
                          child: const Text('Transfer'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Card(
                  margin: const EdgeInsets.all(16),
                  color: Colors.blue[50],
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, color: Colors.blue),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'You are a coach on this team',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'You can add coaches or leave the team',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[700]),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Coaches list ──────────────────────────────────────────────
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: coaches.length,
                  itemBuilder: (context, index) {
                    final coach = coaches[index];
                    final isOwner = coach['is_owner'] == true;
                    final isCurrentUser = coach['id'] == _currentCoachId;

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isOwner
                              ? Colors.amber[100]
                              : Colors.blue[100],
                          child: Icon(
                            isOwner ? Icons.shield : Icons.person,
                            color: isOwner ? Colors.amber[700] : Colors.blue,
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(
                              coach['name'] as String,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            // "YOU" badge for the current user.
                            if (isCurrentUser) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.blue[100],
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'YOU',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue[900],
                                  ),
                                ),
                              ),
                            ],
                            // "OWNER" badge.
                            if (isOwner) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.amber[100],
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'OWNER',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.amber[900],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(coach['role'] as String),
                            Text(
                              coach['email'] as String,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                        trailing: _buildTrailingActions(
                          coach,
                          isOwner,
                          isCurrentUser,
                          isCurrentUserOwner,
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
        onPressed: _showAddCoachDialog,
        icon: const Icon(Icons.person_add),
        label: const Text('Add Coach'),
      ),
    );
  }

  // ── Trailing action buttons per coach row ─────────────────────────────────

  /// Returns the appropriate trailing action widget based on permissions:
  ///  - Cannot remove the owner unless it's the owner removing themselves.
  ///  - Non-owners can only remove themselves (leave).
  Widget? _buildTrailingActions(
    Map<String, dynamic> coach,
    bool isOwner,
    bool isCurrentUser,
    bool isCurrentUserOwner,
  ) {
    // Never allow removing another user's owner badge via this button.
    if (isOwner && !isCurrentUser) return null;

    // Show remove/leave button only for self-removal or owner removing others.
    if (isCurrentUser || isCurrentUserOwner) {
      return IconButton(
        icon: Icon(
          isCurrentUser ? Icons.exit_to_app : Icons.remove_circle,
          color: Colors.red,
        ),
        onPressed: () => _confirmRemoveCoach(coach),
        tooltip: isCurrentUser ? 'Leave team' : 'Remove coach',
      );
    }

    return null;
  }
}