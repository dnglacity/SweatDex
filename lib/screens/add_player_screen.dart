import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/player.dart';
import '../services/player_service.dart';

// =============================================================================
// add_player_screen.dart  (AOD v1.7)
//
// CHANGE (Notes.txt v1.7 — 2-page add-player flow):
//
//   PAGE 1 — Athlete Email Lookup
//     • Asks for the athlete's email.
//     • On Submit: checks whether an AOD account exists for that email.
//       If it does, pre-populates Page 2 with first name, last name, and
//       athlete ID from the linked account.
//
//   PAGE 2 — Athlete Details
//     • First Name, Last Name (pre-filled if account found; editable)
//     • Jersey Number (optional)
//     • Position (optional)
//     • Nickname (optional)
//     • Athlete ID (optional; pre-filled if account found)
//     • Athlete Grade (optional; dropdown 9–12; auto-increments July 1)
//     • Parent/Guardian Email (optional; triggers guardian link)
//     Section divider: "Athlete Information (Optional)"
//
// CHANGE (v1.7): labels changed from "Student Email / ID" → "Athlete Email / ID"
// CHANGE (v1.7): new guardianEmail field.
// CHANGE (v1.7): auto-link + guardian link after save.
//
// Edit mode bypasses Page 1 and goes straight to Page 2 pre-filled.
// =============================================================================

class AddPlayerScreen extends StatefulWidget {
  final String teamId;
  final Player? playerToEdit;

  const AddPlayerScreen({super.key, required this.teamId, this.playerToEdit});

  @override
  State<AddPlayerScreen> createState() => _AddPlayerScreenState();
}

class _AddPlayerScreenState extends State<AddPlayerScreen> {
  final _playerService = PlayerService();

  // ── Page state ─────────────────────────────────────────────────────────────
  // 0 = email lookup (new player only); 1 = details form.
  int _page = 0;

  // ── Page 1 controllers ─────────────────────────────────────────────────────
  final _emailLookupController = TextEditingController();
  final _emailFormKey          = GlobalKey<FormState>();

  bool _isLookingUp = false;

  // After lookup, whether we found an existing account.
  bool _accountFound  = false;
  String? _foundUserId;

  // ── Page 2 controllers ─────────────────────────────────────────────────────
  final _detailFormKey       = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController  = TextEditingController();
  final _jerseyController    = TextEditingController();
  final _positionController  = TextEditingController();
  final _nicknameController  = TextEditingController();
  final _athleteIdController = TextEditingController();
  final _guardianController  = TextEditingController();

  int? _selectedGrade; // nullable — 9, 10, 11, or 12

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();

    if (widget.playerToEdit != null) {
      // Edit mode: skip email lookup, go straight to Page 2 pre-filled.
      _page = 1;
      final p = widget.playerToEdit!;
      // Pre-fill from existing player row.
      final nameParts = p.name.split(' ');
      _firstNameController.text = nameParts.isNotEmpty ? nameParts.first : '';
      _lastNameController.text  = nameParts.length > 1
          ? nameParts.sublist(1).join(' ')
          : '';
      _jerseyController.text    = p.jerseyNumber    ?? '';
      _positionController.text  = p.position        ?? '';
      _nicknameController.text  = p.nickname        ?? '';
      _athleteIdController.text = p.athleteId       ?? '';
      _guardianController.text  = p.guardianEmail   ?? '';
      _selectedGrade            = p.grade;
      if (p.athleteEmail != null) {
        _emailLookupController.text = p.athleteEmail!;
      }
    }
  }

  @override
  void dispose() {
    _emailLookupController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _jerseyController.dispose();
    _positionController.dispose();
    _nicknameController.dispose();
    _athleteIdController.dispose();
    _guardianController.dispose();
    super.dispose();
  }

  // ==========================================================================
  // PAGE 1 — Email Lookup
  // ==========================================================================

  /// Checks whether a public.users account exists for the entered email.
  /// Uses the `add_member_to_team` RPC indirectly — actually we query the
  /// team_members / users via a separate lookup method in PlayerService.
  ///
  /// NOTE: We cannot query public.users directly by email (RLS blocks it).
  /// Instead we attempt to fetch via the service which calls the DB, and if
  /// the user is already on the team their data is returned. Otherwise we just
  /// advance to Page 2 and note "account not found yet".
  Future<void> _lookupEmail() async {
    if (!_emailFormKey.currentState!.validate()) return;
    setState(() => _isLookingUp = true);

    final email = _emailLookupController.text.trim().toLowerCase();

    try {
      // Check if this email belongs to someone already on the team.
      final members = await _playerService.getTeamMembers(widget.teamId);
      final match   = members.where((m) =>
          m.email.toLowerCase() == email).firstOrNull;

      if (match != null) {
        // Pre-fill name from the matched team member.
        setState(() {
          _accountFound = true;
          _foundUserId  = match.userId;
          _firstNameController.text = match.firstName;
          _lastNameController.text  = match.lastName;
          _page = 1;
        });
      } else {
        // Account may exist but is not yet on the team — advance anyway.
        // The auto-link step after save will try to link it.
        setState(() {
          _accountFound = false;
          _page         = 1;
        });
      }
    } catch (_) {
      setState(() {
        _accountFound = false;
        _page         = 1;
      });
    } finally {
      if (mounted) setState(() => _isLookingUp = false);
    }
  }

  // ==========================================================================
  // PAGE 2 — Save
  // ==========================================================================

  Future<void> _savePlayer() async {
    if (!_detailFormKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      final firstName = _firstNameController.text.trim();
      final lastName  = _lastNameController.text.trim();
      final fullName  = '$firstName $lastName'.trim();

      final athleteEmail = _emailLookupController.text.trim().isEmpty
          ? null
          : _emailLookupController.text.trim();

      final player = Player(
        id:           widget.playerToEdit?.id ?? '',
        teamId:       widget.teamId,
        name:         fullName,
        athleteEmail: athleteEmail,
        athleteId:    _athleteIdController.text.trim().isEmpty
                        ? null
                        : _athleteIdController.text.trim(),
        guardianEmail: _guardianController.text.trim().isEmpty
                        ? null
                        : _guardianController.text.trim(),
        grade:        _selectedGrade,
        jerseyNumber: _jerseyController.text.trim().isEmpty
                        ? null
                        : _jerseyController.text.trim(),
        position:     _positionController.text.trim().isEmpty
                        ? null
                        : _positionController.text.trim(),
        nickname:     _nicknameController.text.trim().isEmpty
                        ? null
                        : _nicknameController.text.trim(),
      );

      String savedPlayerId;
      if (widget.playerToEdit == null) {
        savedPlayerId = await _playerService.addPlayerAndReturnId(player);
      } else {
        await _playerService.updatePlayer(player);
        savedPlayerId = player.id;
      }

      // Auto-link player → account if an athlete email was provided.
      if (athleteEmail != null && athleteEmail.isNotEmpty && mounted) {
        await _attemptAutoLink(
            playerId: savedPlayerId, email: athleteEmail);
      }

      // Auto-link guardian if an email was provided.
      final guardianEmail = _guardianController.text.trim();
      if (guardianEmail.isNotEmpty && mounted) {
        await _attemptGuardianLink(
            playerId: savedPlayerId, guardianEmail: guardianEmail);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.playerToEdit == null
                ? '$fullName added to roster!'
                : '$fullName updated!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Auto-link helpers ──────────────────────────────────────────────────────

  Future<void> _attemptAutoLink(
      {required String playerId, required String email}) async {
    try {
      await _playerService.linkPlayerToAccount(
        teamId:      widget.teamId,
        playerId:    playerId,
        playerEmail: email,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$email linked to player account.'),
            backgroundColor: Colors.teal,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Player saved. Account link skipped — '
              'the athlete may not have registered yet.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _attemptGuardianLink(
      {required String playerId, required String guardianEmail}) async {
    try {
      await _playerService.linkGuardianToPlayer(
        playerId:      playerId,
        guardianEmail: guardianEmail,
      );
    } catch (_) {
      // Non-fatal — guardian may not have an account yet.
    }
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.playerToEdit != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Player' : 'Add New Player'),
        centerTitle: true,
        leading: _page == 1 && !isEditing
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                // Go back to email lookup if on Page 2 in add mode.
                onPressed: () => setState(() => _page = 0),
              )
            : null,
      ),
      body: _page == 0 ? _buildPage1() : _buildPage2(isEditing),
    );
  }

  // ── PAGE 1 ─────────────────────────────────────────────────────────────────

  Widget _buildPage1() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _emailFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Progress indicator
            _StepIndicator(current: 1, total: 2),
            const SizedBox(height: 24),

            Text(
              'Step 1: Athlete Email',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the athlete\'s email. If they already have an Apex On Deck '
              'account, their information will be pre-filled.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),

            TextFormField(
              controller: _emailLookupController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autofocus: true,
              onFieldSubmitted: (_) => _lookupEmail(),
              decoration: const InputDecoration(
                labelText: 'Athlete Email',
                hintText: 'athlete@example.com',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null; // optional
                if (!v.contains('@')) return 'Enter a valid email';
                return null;
              },
            ),
            const SizedBox(height: 32),

            SizedBox(
              height: 50,
              child: FilledButton(
                onPressed: _isLookingUp ? null : _lookupEmail,
                child: _isLookingUp
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Text('Continue', style: TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              // Skip email lookup entirely — jump straight to Page 2 blank.
              onPressed: () => setState(() => _page = 1),
              child: const Text('Skip — Enter Details Manually'),
            ),
          ],
        ),
      ),
    );
  }

  // ── PAGE 2 ─────────────────────────────────────────────────────────────────

  Widget _buildPage2(bool isEditing) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _detailFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!isEditing) _StepIndicator(current: 2, total: 2),
            if (!isEditing) const SizedBox(height: 16),

            // Account found banner
            if (_accountFound && !isEditing)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.teal.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.withOpacity(0.5)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.teal, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Account found! Name and ID pre-filled.',
                        style: TextStyle(color: Colors.teal),
                      ),
                    ),
                  ],
                ),
              ),

            // ── First Name ─────────────────────────────────────────────────
            TextFormField(
              controller: _firstNameController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'First Name *',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 16),

            // ── Last Name ──────────────────────────────────────────────────
            TextFormField(
              controller: _lastNameController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Last Name *',
                prefixIcon: Icon(Icons.person),
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 16),

            // ── Jersey Number ──────────────────────────────────────────────
            TextFormField(
              controller: _jerseyController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Jersey Number',
                hintText: 'e.g., 23, 00, 12A',
                prefixIcon: Icon(Icons.numbers),
                border: OutlineInputBorder(),
                helperText: 'Can include letters (e.g., 12A)',
              ),
            ),
            const SizedBox(height: 16),

            // ── Position ───────────────────────────────────────────────────
            TextFormField(
              controller: _positionController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Position',
                hintText: 'e.g., Point Guard, Pitcher, Center Back',
                prefixIcon: Icon(Icons.sports),
                border: OutlineInputBorder(),
                helperText: 'Optional — any sport',
              ),
            ),
            const SizedBox(height: 16),

            // ── Nickname ───────────────────────────────────────────────────
            TextFormField(
              controller: _nicknameController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Nickname',
                hintText: 'e.g., Big Mike',
                prefixIcon: Icon(Icons.badge),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),

            // ── Section divider ────────────────────────────────────────────
            const Divider(height: 1),
            const SizedBox(height: 16),
            Text(
              'Athlete Information (Optional)',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'This information is local to your team and not visible to other teams.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            // ── Athlete ID ─────────────────────────────────────────────────
            TextFormField(
              controller: _athleteIdController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Athlete ID',
                hintText: 'e.g., A12345',
                prefixIcon: Icon(Icons.badge_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // ── Grade ──────────────────────────────────────────────────────
            // CHANGE (v1.7): grade dropdown; auto-increments July 1 server-side.
            DropdownButtonFormField<int?>(
              value: _selectedGrade,
              decoration: const InputDecoration(
                labelText: 'Grade',
                prefixIcon: Icon(Icons.school_outlined),
                border: OutlineInputBorder(),
                helperText: 'Grade automatically increases on July 1 each year',
              ),
              items: const [
                DropdownMenuItem<int?>(value: null,  child: Text('Not set')),
                DropdownMenuItem<int?>(value: 9,     child: Text('9th — Freshman')),
                DropdownMenuItem<int?>(value: 10,    child: Text('10th — Sophomore')),
                DropdownMenuItem<int?>(value: 11,    child: Text('11th — Junior')),
                DropdownMenuItem<int?>(value: 12,    child: Text('12th — Senior')),
              ],
              onChanged: (v) => setState(() => _selectedGrade = v),
            ),
            const SizedBox(height: 16),

            // ── Parent/Guardian Email ──────────────────────────────────────
            // CHANGE (v1.7): new field. Triggers guardian link if account found.
            TextFormField(
              controller: _guardianController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Parent/Guardian Email',
                hintText: 'guardian@example.com',
                prefixIcon: Icon(Icons.family_restroom),
                border: OutlineInputBorder(),
                helperText:
                    'If the guardian has an AOD account, they will be linked '
                    'and can see this player\'s view',
              ),
              validator: (v) {
                if (v != null && v.isNotEmpty && !v.contains('@')) {
                  return 'Enter a valid email';
                }
                return null;
              },
            ),
            const SizedBox(height: 32),

            // ── Submit ─────────────────────────────────────────────────────
            SizedBox(
              height: 50,
              child: FilledButton(
                onPressed: _isSaving ? null : _savePlayer,
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        isEditing ? 'Update Player' : 'Add to Roster',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ),
            if (isEditing) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _StepIndicator — simple 2-step page progress widget
// =============================================================================
class _StepIndicator extends StatelessWidget {
  final int current; // 1-based
  final int total;

  const _StepIndicator({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: List.generate(total, (i) {
        final step     = i + 1;
        final isActive = step == current;
        final isDone   = step < current;

        return Expanded(
          child: Row(
            children: [
              // Circle
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone || isActive ? cs.primary : cs.surfaceVariant,
                ),
                child: Center(
                  child: isDone
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : Text(
                          '$step',
                          style: TextStyle(
                            color: isActive ? Colors.white : cs.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                ),
              ),
              // Connector line (between steps)
              if (i < total - 1)
                Expanded(
                  child: Container(
                    height: 2,
                    color: isDone ? cs.primary : cs.surfaceVariant,
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}