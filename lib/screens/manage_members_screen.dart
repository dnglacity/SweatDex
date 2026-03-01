import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../services/player_service.dart';
import '../widgets/error_dialog.dart';
import 'account_settings_screen.dart';

// =============================================================================
// manage_members_screen.dart  (AOD v1.9)
//
// BUG FIX (Issue 1 / 1.2 / 1.3 — TextEditingController used after dispose):
//   _showAddMemberDialog() created emailController locally, then called
//   emailController.dispose() synchronously right after showDialog() returned.
//   Flutter's closing animation still held a reference to the TextFormField
//   on the very next frame, causing the "used after being disposed" assertion.
//
//   Fix: moved emailController.dispose() into a
//   WidgetsBinding.instance.addPostFrameCallback so it is deferred to the
//   frame AFTER the dialog's exit animation completes — consistent with the
//   pattern already used in saved_roster_screen.dart and team_selection_screen.dart.
//
//   The same deferred-dispose pattern is now applied to _showLinkPlayerDialog()
//   for the same reason.
//
// BUG FIX (Issue 1.2 — FK violation team_members_user_id_fkey):
//   The RPC add_member_to_team resolves the public.users.id from the email
//   internally.  The Flutter side must NOT attempt to resolve or pass a raw
//   auth.uid — it passes only the email and role, which is already the case.
//   No Flutter code change required beyond the dispose fix above.
//
// CHANGE (Notes.txt v1.8 — email change flow):
//   This screen now opens AccountSettingsScreen which handles the full
//   password-gated email change flow (see account_settings_screen.dart).
//
// PERF (v1.9 — abandoned-future fix):
//   Replaced FutureBuilder + late Future<List<TeamMember>> _membersFuture with
//   a state-driven pattern (_members list + _isLoading bool + _loadError).
//   A generation counter (_loadGen) ensures that results from a superseded
//   refresh call are silently discarded, preventing stale data from overwriting
//   a newer result when the user rapidly triggers refreshes.
//
// All v1.8 behaviours retained.
// =============================================================================

class ManageMembersScreen extends StatefulWidget {
  final String teamId;
  final String teamName;
  final String currentUserRole;

  const ManageMembersScreen({
    super.key,
    required this.teamId,
    required this.teamName,
    required this.currentUserRole,
  });

  @override
  State<ManageMembersScreen> createState() => _ManageMembersScreenState();
}

class _ManageMembersScreenState extends State<ManageMembersScreen> {
  final _playerService = PlayerService();

  // State-driven member list — replaces the old FutureBuilder + _membersFuture.
  // _loadGen increments on every refresh so stale completions are discarded.
  List<TeamMember> _members      = [];
  bool             _isLoading    = true;
  bool             _isSubmitting = false;
  Object?          _loadError;
  int              _loadGen      = 0;

  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    // Load the current user ID first, then fetch members so that the YOU
    // badge and isSelf leave-team logic are correct on first render.
    _loadCurrentUser().then((_) => _refreshMembers());
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  Future<void> _loadCurrentUser() async {
    try {
      final user = await _playerService.getCurrentUser();
      if (mounted) setState(() => _currentUserId = user?['id'] as String?);
    } catch (e) {
      debugPrint('Error loading current user: $e');
    }
  }

  Future<void> _refreshMembers() async {
    // Stamp the generation before the async gap so any concurrent call that
    // starts later will have a higher gen and win; this call's result will be
    // discarded if a newer one completes first.
    final gen = ++_loadGen;
    if (mounted) setState(() { _isLoading = true; _loadError = null; });

    try {
      final result = await _playerService.getTeamMembers(widget.teamId);
      if (mounted && gen == _loadGen) {
        setState(() { _members = result; _isLoading = false; });
      }
    } catch (e) {
      if (mounted && gen == _loadGen) {
        setState(() { _loadError = e; _isLoading = false; });
      }
    }
  }

  // ── Role helpers ──────────────────────────────────────────────────────────

  bool get _isOwner => widget.currentUserRole == 'owner';
  bool get _isCoachOrOwner =>
      widget.currentUserRole == 'owner' || widget.currentUserRole == 'coach';

  // ── Add member dialog ─────────────────────────────────────────────────────

  Future<void> _showAddMemberDialog() async {
    // Controller is created locally here; must be disposed only after the
    // dialog's exit animation is fully complete (see BUG FIX above).
    final emailController = TextEditingController();
    final formKey         = GlobalKey<FormState>();

    String selectedRole = 'coach';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add Team Member'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The person must already have an Apex On Deck account.',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),

                // Email input.
                TextFormField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email Address',
                    hintText: 'member@example.com',
                    prefixIcon: Icon(Icons.email),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Please enter an email';
                    }
                    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) {
                      return 'Enter a valid email';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Role selector — owners get all 4 non-owner roles.
                if (_isOwner)
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: const InputDecoration(
                      labelText: 'Role',
                      prefixIcon: Icon(Icons.badge),
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'coach',        child: Text('Coach')),
                      DropdownMenuItem(value: 'player',       child: Text('Player')),
                      DropdownMenuItem(value: 'team_parent',  child: Text('Team Parent')),
                      DropdownMenuItem(value: 'team_manager', child: Text('Team Manager')),
                    ],
                    onChanged: (v) => setLocal(() => selectedRole = v!),
                  )
                else
                  const Text('Role: Coach',
                      style: TextStyle(fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    // BUG FIX (Issue 1): Capture text BEFORE deferring dispose.
    // Reading .text after dispose() would throw; capture it now while the
    // controller is still alive.
    final email = emailController.text.trim();

    // Defer dispose to the next frame so Flutter's dialog closing animation
    // can finish detaching the TextFormField from the controller first.
    WidgetsBinding.instance.addPostFrameCallback((_) => emailController.dispose());

    if (result == true && mounted) {
      setState(() => _isSubmitting = true);
      try {
        // Calls the add_member_to_team SECURITY DEFINER RPC which resolves
        // the user by email inside the DB, bypassing RLS on public.users.
        await _playerService.addMemberToTeam(
          teamId:    widget.teamId,
          userEmail: email,
          role:      selectedRole,
        );
        _refreshMembers();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Member added!'),
                backgroundColor: Colors.green),
          );
        }
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
        }
      } finally {
        if (mounted) setState(() => _isSubmitting = false);
      }
    }
  }

  // ── Link player dialog ────────────────────────────────────────────────────

  Future<void> _showLinkPlayerDialog() async {
    // Show the loading overlay while the player list is fetched so the user
    // gets immediate feedback after dismissing the FAB menu.
    if (mounted) setState(() => _isSubmitting = true);

    List<Map<String, dynamic>> players = [];
    try {
      final raw = await _playerService.getPlayers(widget.teamId);
      players = raw
          .map((p) => {'id': p.id, 'name': p.name, 'jersey': p.jerseyNumber})
          .toList();
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading players: $e')),
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }

    if (players.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No players on this team to link.')),
        );
      }
      return;
    }

    // BUG FIX: create controller here so we can defer its dispose.
    final emailController   = TextEditingController();
    final formKey           = GlobalKey<FormState>();
    String? selectedPlayerId;

    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Link Player → Account'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Enter the player's registered email and select their "
                    'roster entry.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: selectedPlayerId,
                    decoration: const InputDecoration(
                      labelText: 'Select Player',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    items: players
                        .map((p) => DropdownMenuItem<String>(
                              value: p['id'] as String,
                              child: Text(
                                '${p['name']}'
                                '${p['jersey'] != null ? ' (#${p['jersey']})' : ''}',
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setLocal(() => selectedPlayerId = v),
                    validator: (_) => selectedPlayerId == null
                        ? 'Please select a player'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: "Player's Account Email",
                      hintText: 'player@example.com',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Please enter an email';
                      }
                      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) {
                      return 'Enter a valid email';
                    }
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Link'),
            ),
          ],
        ),
      ),
    );

    // Capture text before deferring dispose (same pattern as above).
    final email = emailController.text.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => emailController.dispose());

    if (result == true && selectedPlayerId != null && mounted) {
      setState(() => _isSubmitting = true);
      try {
        await _playerService.linkPlayerToAccount(
          teamId:      widget.teamId,
          playerId:    selectedPlayerId!,
          playerEmail: email,
        );
        _refreshMembers();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Player linked to account!'),
                backgroundColor: Colors.green),
          );
        }
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
        }
      } finally {
        if (mounted) setState(() => _isSubmitting = false);
      }
    }
  }

  // ── Remove member ─────────────────────────────────────────────────────────

  Future<void> _confirmRemoveMember(TeamMember member) async {
    final isSelf = member.userId == _currentUserId;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isSelf ? 'Leave Team' : 'Remove Member'),
        content: Text(
          isSelf
              ? 'Are you sure you want to leave "${widget.teamName}"?'
              : 'Remove ${member.name} from this team?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(isSelf ? 'Leave' : 'Remove'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      setState(() => _isSubmitting = true);
      try {
        await _playerService.removeMemberFromTeam(
            widget.teamId, member.userId);

        if (!mounted) return;

        if (isSelf) {
          // BUG FIX (Bug 8 — retained): Pop to root when user leaves own team.
          Navigator.of(context).popUntil((route) => route.isFirst);
          return;
        }

        _refreshMembers();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${member.name} removed')),
        );
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
        }
      } finally {
        if (mounted) setState(() => _isSubmitting = false);
      }
    }
  }

  // ── Change role dialog ────────────────────────────────────────────────────

  Future<void> _showChangeRoleDialog(TeamMember member) async {
    const roles = ['coach', 'player', 'team_parent', 'team_manager'];
    String selected = roles.contains(member.role) ? member.role : 'coach';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Change Role — ${member.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: roles.map((r) {
              final label = {
                'coach':        'Coach',
                'player':       'Player',
                'team_parent':  'Team Parent',
                'team_manager': 'Team Manager',
              }[r]!;
              return RadioListTile<String>(
                value: r,
                groupValue: selected,
                title: Text(label),
                onChanged: (v) => setLocal(() => selected = v!),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (confirm == true && selected != member.role && mounted) {
      setState(() => _isSubmitting = true);
      try {
        await _playerService.updateMemberRole(
          teamId:  widget.teamId,
          userId:  member.userId,
          newRole: selected,
        );
        _refreshMembers();
        if (mounted) {
          const roleLabels = {
            'coach':        'Coach',
            'player':       'Player',
            'team_parent':  'Team Parent',
            'team_manager': 'Team Manager',
          };
          final label = roleLabels[selected] ?? selected;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text("${member.name}'s role updated to $label")),
          );
        }
      } catch (e) {
        if (mounted) {
          showErrorDialog(context, e);
        }
      } finally {
        if (mounted) setState(() => _isSubmitting = false);
      }
    }
  }

  // ── Transfer ownership dialog ─────────────────────────────────────────────

  Future<void> _showTransferOwnershipDialog(
      List<TeamMember> members) async {
    final eligible = members.where((m) => !m.isOwner).toList();

    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No other members to transfer to.')),
      );
      return;
    }

    final selected = await showDialog<TeamMember>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Transfer Ownership'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: eligible.map((m) {
              return ListTile(
                leading: CircleAvatar(
                  child: Text(
                      m.firstName.isNotEmpty ? m.firstName[0].toUpperCase() : '?'),
                ),
                title: Text(m.name),
                subtitle: Text(m.roleLabel),
                onTap: () => Navigator.pop(ctx, m),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selected != null && mounted) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Transfer'),
          content: Text(
            'Transfer team ownership to ${selected.name}?\n\n'
            'You will remain on the team as a Coach.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Transfer'),
            ),
          ],
        ),
      );

      if (confirm == true && mounted) {
        setState(() => _isSubmitting = true);
        try {
          await _playerService.transferOwnership(
              widget.teamId, selected.userId);
          _refreshMembers();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(
                      'Ownership transferred to ${selected.name}')),
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
        } finally {
          if (mounted) setState(() => _isSubmitting = false);
        }
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.teamName} Members'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          _buildBody(),
          if (_isSubmitting)
            const Opacity(
              opacity: 0.6,
              child: ModalBarrier(dismissible: false, color: Colors.black),
            ),
          if (_isSubmitting)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
      floatingActionButton: _isCoachOrOwner
          ? FloatingActionButton.extended(
              onPressed: _showFabMenu,
              icon: const Icon(Icons.add),
              label: const Text('Actions'),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            const Text('Could not load team members.'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _refreshMembers,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final currentMember = _members.firstWhere(
      (m) => m.userId == _currentUserId,
      orElse: () => TeamMember(
        teamMemberId: '',
        teamId:       widget.teamId,
        userId:       '',
        role:         widget.currentUserRole,
        firstName:    '',
        lastName:     '',
        email:        '',
      ),
    );

    return Column(
      children: [
        _RoleBanner(
          role: currentMember.role.isNotEmpty
              ? currentMember.role
              : widget.currentUserRole,
          onTransferOwnership: _isOwner
              ? () => _showTransferOwnershipDialog(_members)
              : null,
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _members.length,
            itemBuilder: (_, i) {
              final m             = _members[i];
              final isCurrentUser = m.userId == _currentUserId;
              return _MemberTile(
                member:              m,
                isCurrentUser:       isCurrentUser,
                isCurrentUserOwner:  _isOwner,
                isCurrentUserCoach:  _isCoachOrOwner,
                onRemove:            () => _confirmRemoveMember(m),
                onChangeRole: _isOwner && !m.isOwner
                    ? () => _showChangeRoleDialog(m)
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }

  void _showFabMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_add),
              title: const Text('Add Team Member'),
              subtitle: const Text('Invite by email with a role'),
              onTap: () {
                Navigator.pop(ctx);
                _showAddMemberDialog();
              },
            ),
            if (_isOwner)
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Link Player → Account'),
                subtitle: const Text(
                    'Connect a roster player row to their app account'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showLinkPlayerDialog();
                },
              ),
            // Account Settings always accessible.
            ListTile(
              leading: const Icon(Icons.manage_accounts),
              title: const Text('Account Settings'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AccountSettingsScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _RoleBanner
// =============================================================================
class _RoleBanner extends StatelessWidget {
  final String role;
  final VoidCallback? onTransferOwnership;

  const _RoleBanner({required this.role, this.onTransferOwnership});

  @override
  Widget build(BuildContext context) {
    final isOwner   = role == 'owner';
    final isPlayer  = role == 'player';
    final isManager = role == 'team_manager';
    final isParent  = role == 'team_parent';

    final color = isOwner   ? Colors.amber
                : isPlayer  ? Theme.of(context).colorScheme.primary
                : isParent  ? Colors.green
                : isManager ? Colors.purple
                : Colors.blue;

    final icon = isOwner   ? Icons.shield
               : isPlayer  ? Icons.directions_run
               : isParent  ? Icons.family_restroom
               : isManager ? Icons.assignment_ind
               : Icons.person;

    final title = isOwner   ? 'You are the team owner'
                : isPlayer  ? 'You are a player on this team'
                : isParent  ? 'You are a team parent'
                : isManager ? 'You are a team manager'
                : 'You are a coach on this team';

    final subtitle = isOwner
        ? 'You can manage all members, link players, and transfer ownership.'
        : isPlayer
            ? 'Contact your coach to change your team settings.'
            : isParent
                ? 'You can view your player\'s information.'
                : isManager
                    ? 'You can help manage team logistics.'
                    : 'You can add coaches and manage the roster.';

    return Card(
      margin: const EdgeInsets.all(16),
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey[700])),
                ],
              ),
            ),
            if (onTransferOwnership != null)
              TextButton(
                onPressed: onTransferOwnership,
                child: const Text('Transfer'),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _MemberTile
// =============================================================================
class _MemberTile extends StatelessWidget {
  final TeamMember  member;
  final bool        isCurrentUser;
  final bool        isCurrentUserOwner;
  final bool        isCurrentUserCoach;
  final VoidCallback onRemove;
  final VoidCallback? onChangeRole;

  const _MemberTile({
    required this.member,
    required this.isCurrentUser,
    required this.isCurrentUserOwner,
    required this.isCurrentUserCoach,
    required this.onRemove,
    this.onChangeRole,
  });

  Color _roleColor(BuildContext context) {
    switch (member.role) {
      case 'owner':        return Colors.amber;
      case 'coach':        return Colors.blue;
      case 'player':       return Theme.of(context).colorScheme.primary;
      case 'team_parent':  return Colors.green;
      case 'team_manager': return Colors.purple;
      default:             return Colors.grey;
    }
  }

  IconData _roleIcon() {
    switch (member.role) {
      case 'owner':        return Icons.shield;
      case 'coach':        return Icons.manage_accounts;
      case 'player':       return Icons.directions_run;
      case 'team_parent':  return Icons.family_restroom;
      case 'team_manager': return Icons.assignment_ind;
      default:             return Icons.person;
    }
  }

  @override
  Widget build(BuildContext context) {
    final roleColor = _roleColor(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: roleColor.withValues(alpha: 0.15),
          child: Icon(_roleIcon(), color: roleColor),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                member.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isCurrentUser) ...[
              const SizedBox(width: 6),
              _Badge('YOU', Colors.blue[900]!, Colors.blue[100]!),
            ],
            const SizedBox(width: 6),
            _Badge(
              member.roleLabel,
              roleColor,
              roleColor.withValues(alpha: 0.12),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(member.email,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis),
            if (member.organization != null &&
                member.organization!.isNotEmpty)
              Text(member.organization!,
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey[600])),
          ],
        ),
        isThreeLine: member.organization != null,
        trailing: _buildTrailing(context),
      ),
    );
  }

  Widget? _buildTrailing(BuildContext context) {
    final canRemove = isCurrentUser ||
        (isCurrentUserOwner && !member.isOwner);

    if (!canRemove && onChangeRole == null) return null;

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        if (v == 'remove') onRemove();
        if (v == 'changeRole') onChangeRole?.call();
      },
      itemBuilder: (_) => [
        if (onChangeRole != null)
          const PopupMenuItem(
            value: 'changeRole',
            child: Row(children: [
              Icon(Icons.swap_horiz, size: 18),
              SizedBox(width: 10),
              Text('Change Role'),
            ]),
          ),
        if (canRemove)
          PopupMenuItem(
            value: 'remove',
            child: Row(children: [
              Icon(
                isCurrentUser ? Icons.exit_to_app : Icons.remove_circle,
                color: Colors.red,
                size: 18,
              ),
              const SizedBox(width: 10),
              Text(
                isCurrentUser ? 'Leave Team' : 'Remove',
                style: const TextStyle(color: Colors.red),
              ),
            ]),
          ),
      ],
    );
  }
}

// =============================================================================
// _Badge
// =============================================================================
class _Badge extends StatelessWidget {
  final String label;
  final Color  textColor;
  final Color  bgColor;

  const _Badge(this.label, this.textColor, this.bgColor);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: textColor),
      ),
    );
  }
}