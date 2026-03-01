import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/player.dart';
import '../services/player_service.dart';
import '../widgets/error_dialog.dart';

// =============================================================================
// add_player_screen.dart  (AOD v1.9 — BUG FIX Issue 1)
//
// BUG FIX (Issue 1 — "Add to roster" fails to link player to user):
//
//   ROOT CAUSE:
//     After a successful email lookup on Page 1, `_foundUserId` was stored
//     from the lookup result, but was NEVER passed into the `Player` object
//     constructed in `_savePlayer()`. The player was therefore inserted with
//     `user_id = null` even when a matching account was found.
//
//     The subsequent `_attemptAutoLink()` call routes to the
//     `link_player_to_user` RPC which performs:
//       UPDATE players SET user_id = <resolved_uid>
//       WHERE id = p_player_id AND user_id IS NULL
//     This UPDATE still succeeds, but relies on the RPC resolving the user
//     by email internally. When the RPC was not called (e.g. edit mode, or
//     error path), the link was permanently lost.
//
//   FIX (this file):
//     1. `_foundUserId` field added to `_AddPlayerScreenState`.
//     2. `_lookupEmail()` sets `_foundUserId = userRow['id']` on match.
//     3. `_savePlayer()` passes `userId: _foundUserId` when building the
//        `Player` object so the INSERT carries the correct `user_id` in a
//        single round-trip — no separate UPDATE or RPC call is required for
//        the happy path.
//     4. `_attemptAutoLink()` is retained as a safety net for cases where
//        the coach skips lookup but provides an athlete email, so the link
//        can still be established if the athlete has an existing account.
//
// All v1.8 behaviours retained:
//   – 2-page flow (email lookup → details form).
//   – Grade dropdown, guardian link, position, nickname, athlete ID.
//   – Auto-link guardian email via `_attemptGuardianLink()`.
//   – Deferred TextEditingController disposal pattern.
// =============================================================================

class AddPlayerScreen extends StatefulWidget {
  /// The team this player belongs to.
  final String teamId;

  /// If non-null, the screen opens in edit mode pre-filled with this player.
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

  // ── Page 1 controllers & state ─────────────────────────────────────────────
  final _emailLookupController = TextEditingController();
  final _emailFormKey          = GlobalKey<FormState>();

  bool _isLookingUp = false;

  // Whether a matching AOD account was found for the entered email.
  bool _accountFound = false;

  // BUG FIX (Issue 1): stores the public.users.id resolved on Page 1.
  // Passed into the Player object on Page 2 so the INSERT carries user_id.
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

  // Selected grade (9–12 or null = not set).
  int? _selectedGrade;

  bool _isSaving = false;

  // Jersey uniqueness warning — loaded once when Page 2 first appears.
  Set<String> _takenJerseys = {};
  bool _jerseyWarning = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    if (widget.playerToEdit != null) {
      // Edit mode: skip email lookup, go straight to Page 2 pre-filled.
      _page = 1;
      // Load taken jerseys after the first frame so context is available.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadTakenJerseys());
      final p = widget.playerToEdit!;

      _firstNameController.text = p.firstName;
      _lastNameController.text  = p.lastName;

      _jerseyController.text    = p.jerseyNumber  ?? '';
      _positionController.text  = p.position      ?? '';
      _nicknameController.text  = p.nickname       ?? '';
      _athleteIdController.text = p.athleteId      ?? '';
      _guardianController.text  = p.guardianEmail  ?? '';
      _selectedGrade            = p.grade;

      // Pre-fill the email lookup field so it is visible on Page 2.
      if (p.athleteEmail != null) {
        _emailLookupController.text = p.athleteEmail!;
      }

      // In edit mode carry the existing userId forward (may be null).
      _foundUserId = p.userId;
    }
  }

  @override
  void dispose() {
    // Dispose all controllers when the widget leaves the tree.
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

  /// Looks up an existing AOD account by the entered email address.
  ///
  /// On success:
  ///   – Sets `_foundUserId` to the resolved public.users.id.
  ///   – Pre-fills the name and athlete ID fields on Page 2.
  ///   – Advances to Page 2.
  ///
  /// On failure or no account:
  ///   – Clears `_foundUserId` (no link will be set at insert time).
  ///   – Advances to Page 2 for manual entry.
  ///
  /// BUG FIX (v1.8 lookup + v1.9 link):
  ///   Previously searched only team members. Now calls the
  ///   `lookup_user_by_email` SECURITY DEFINER RPC which can see ALL
  ///   registered users regardless of RLS.
  Future<void> _lookupEmail() async {
    if (!_emailFormKey.currentState!.validate()) return;
    setState(() => _isLookingUp = true);

    final email = _emailLookupController.text.trim().toLowerCase();

    try {
      // RPC-based lookup — bypasses RLS on public.users.
      final userRow = await _playerService.lookupUserByEmail(email);

      if (userRow != null) {
        // Account found — pre-fill and store the resolved user ID.
        setState(() {
          _accountFound = true;

          // BUG FIX (Issue 1): capture the resolved public.users.id so it
          // can be passed into the Player object during _savePlayer().
          _foundUserId = userRow['id'] as String?;

          // Pre-fill name and athlete ID from the account row.
          _firstNameController.text = userRow['first_name'] as String? ?? '';
          _lastNameController.text  = userRow['last_name']  as String? ?? '';
          _athleteIdController.text = userRow['athlete_id'] as String? ?? '';

          _page = 1;
        });
        _loadTakenJerseys();
      } else {
        // No account found — advance without a userId.
        // The auto-link will be retried after save via _attemptAutoLink().
        setState(() {
          _accountFound = false;
          _foundUserId  = null; // explicit clear
          _page         = 1;
        });
        _loadTakenJerseys();
      }
    } catch (_) {
      // Non-fatal — advance to Page 2 so the coach can still add the player.
      setState(() {
        _accountFound = false;
        _foundUserId  = null;
        _page         = 1;
      });
      _loadTakenJerseys();
    } finally {
      if (mounted) setState(() => _isLookingUp = false);
    }
  }

  // ── Jersey uniqueness ───────────────────────────────────────────────────────

  /// Fetches taken jersey numbers for the team, then checks the current field.
  /// Called once when the form advances to Page 2.
  Future<void> _loadTakenJerseys() async {
    try {
      final taken = await _playerService.getJerseyNumbers(widget.teamId);
      // In edit mode, remove the player's own current jersey so editing it
      // back to the same value doesn't trigger a false warning.
      final ownJersey = widget.playerToEdit?.jerseyNumber?.toUpperCase();
      if (ownJersey != null) taken.remove(ownJersey);
      if (!mounted) return;
      setState(() {
        _takenJerseys = taken;
        _jerseyWarning = _isJerseyTaken();
      });
    } catch (_) {
      // Non-fatal — skip the warning if we can't fetch.
    }
  }

  bool _isJerseyTaken() {
    final val = _jerseyController.text.trim().toUpperCase();
    return val.isNotEmpty && _takenJerseys.contains(val);
  }

  void _onJerseyChanged(String _) {
    final warn = _isJerseyTaken();
    if (warn != _jerseyWarning) setState(() => _jerseyWarning = warn);
  }

  // ==========================================================================
  // PAGE 2 — Save Player
  // ==========================================================================

  Future<void> _savePlayer() async {
    if (!_detailFormKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      final firstName = _firstNameController.text.trim();
      final lastName  = _lastNameController.text.trim();
      final fullName  = '$firstName $lastName'.trim(); // used for snackbar messages

      // Use the athlete email if one was entered on Page 1.
      final athleteEmail = _emailLookupController.text.trim().isEmpty
          ? null
          : _emailLookupController.text.trim();

      // Build the player object.
      // BUG FIX (Issue 1): include `userId: _foundUserId` so the INSERT
      // carries the correct user_id in one step rather than requiring a
      // separate RPC call to set it afterwards.
      final player = Player(
        id:           widget.playerToEdit?.id ?? '',
        teamId:       widget.teamId,
        firstName:    firstName,
        lastName:     lastName,
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
        // BUG FIX (Issue 1): pass the resolved user ID so the row is linked
        // immediately at insert time. Null if no account was found or the
        // coach skipped the lookup step.
        userId:       _foundUserId,
      );

      String savedPlayerId;
      if (widget.playerToEdit == null) {
        // New player — insert and get the generated UUID back.
        savedPlayerId = await _playerService.addPlayerAndReturnId(player);
      } else {
        // Edit mode — update the existing row.
        await _playerService.updatePlayer(player);
        savedPlayerId = player.id;
      }

      // Safety-net auto-link: if an athlete email was provided but _foundUserId
      // Always call the RPC when an athlete email is provided.
      // The RPC sets players.user_id (no-op if already set) AND upserts the
      // team_members row — which is the step that grants the athlete access.
      if (athleteEmail != null && athleteEmail.isNotEmpty && mounted) {
        await _attemptAutoLink(playerId: savedPlayerId, email: athleteEmail);
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
        showErrorDialog(context, e);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Auto-link helpers ──────────────────────────────────────────────────────

  /// Calls the link_player_to_user RPC to set players.user_id by email.
  /// Used as a safety net when the userId was not resolved at lookup time.
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
      // Non-fatal — the athlete may not have registered yet.
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

  /// Links a guardian email to the player row via RPC.
  /// Non-fatal — the guardian may not have an account yet.
  Future<void> _attemptGuardianLink(
      {required String playerId, required String guardianEmail}) async {
    try {
      await _playerService.linkGuardianToPlayer(
        playerId:      playerId,
        guardianEmail: guardianEmail,
      );
    } catch (_) {
      // Non-fatal — logged inside PlayerService.
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
        // Show a back button on Page 2 (new player only) to return to lookup.
        leading: _page == 1 && !isEditing
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _page = 0;
                  // Clear the account-found state when going back.
                  _accountFound = false;
                  _foundUserId  = null;
                }),
              )
            : null,
      ),
      body: _page == 0 ? _buildPage1() : _buildPage2(isEditing),
    );
  }

  // ── PAGE 1 — Email lookup ──────────────────────────────────────────────────

  Widget _buildPage1() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _emailFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
              "Enter the athlete's email. If they already have an Apex On Deck "
              'account, their information will be pre-filled and they will be '
              'linked automatically.',
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
                // Email is optional on Page 1 — coaches may skip the lookup.
                if (v == null || v.trim().isEmpty) return null;
                if (!v.contains('@')) return 'Enter a valid email';
                return null;
              },
            ),
            const SizedBox(height: 32),

            // Continue: run the lookup, then advance to Page 2.
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

            // Skip: advance to Page 2 without running the lookup.
            OutlinedButton(
              onPressed: () {
                setState(() {
                  _foundUserId  = null;
                  _accountFound = false;
                  _page         = 1;
                });
                _loadTakenJerseys();
              },
              child: const Text('Skip — Enter Details Manually'),
            ),
          ],
        ),
      ),
    );
  }

  // ── PAGE 2 — Player details form ───────────────────────────────────────────

  Widget _buildPage2(bool isEditing) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _detailFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Step indicator (new player only).
            if (!isEditing) _StepIndicator(current: 2, total: 2),
            if (!isEditing) const SizedBox(height: 16),

            // Account-found confirmation banner.
            if (_accountFound && !isEditing)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.withValues(alpha: 0.5)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.teal, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Account found! Name and ID pre-filled. '
                        'This player will be linked automatically.',
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
              onChanged: _onJerseyChanged,
              // Limit jersey to 10 characters to prevent layout overflow.
              inputFormatters: [LengthLimitingTextInputFormatter(10)],
              decoration: const InputDecoration(
                labelText: 'Jersey Number',
                hintText: 'e.g., 23, 00, 12A',
                prefixIcon: Icon(Icons.numbers),
                border: OutlineInputBorder(),
                helperText: 'Can include letters (e.g., 12A)',
              ),
            ),
            if (_jerseyWarning) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: Colors.orange[700]),
                  const SizedBox(width: 6),
                  Text(
                    'Jersey #${_jerseyController.text.trim()} is already assigned '
                    'to another player on this team.',
                    style: TextStyle(
                        color: Colors.orange[700], fontSize: 12),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),

            // ── Position ───────────────────────────────────────────────────
            TextFormField(
              controller: _positionController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              // Limit position to 50 characters.
              inputFormatters: [LengthLimitingTextInputFormatter(50)],
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
              inputFormatters: [LengthLimitingTextInputFormatter(50)],
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
              'This information is local to your team and not visible to '
              'other teams.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            // ── Athlete Email (edit mode only — new players use Page 1) ───
            if (isEditing) ...[
              TextFormField(
                controller: _emailLookupController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Athlete Email',
                  hintText: 'athlete@example.com',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                  helperText:
                      'Changing this will re-attempt account linking on save',
                ),
                validator: (v) {
                  if (v != null && v.isNotEmpty && !v.contains('@')) {
                    return 'Enter a valid email';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
            ],

            // ── Athlete ID ─────────────────────────────────────────────────
            TextFormField(
              controller: _athleteIdController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              inputFormatters: [LengthLimitingTextInputFormatter(30)],
              decoration: const InputDecoration(
                labelText: 'Athlete ID',
                hintText: 'e.g., A12345',
                prefixIcon: Icon(Icons.badge_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // ── Grade ──────────────────────────────────────────────────────
            DropdownButtonFormField<int?>(
              initialValue: _selectedGrade,
              decoration: const InputDecoration(
                labelText: 'Grade',
                prefixIcon: Icon(Icons.school_outlined),
                border: OutlineInputBorder(),
                helperText:
                    'Grade automatically increases on July 1 each year',
              ),
              items: const [
                DropdownMenuItem<int?>(
                    value: null, child: Text('Not set')),
                DropdownMenuItem<int?>(
                    value: 9, child: Text('9th — Freshman')),
                DropdownMenuItem<int?>(
                    value: 10, child: Text('10th — Sophomore')),
                DropdownMenuItem<int?>(
                    value: 11, child: Text('11th — Junior')),
                DropdownMenuItem<int?>(
                    value: 12, child: Text('12th — Senior')),
              ],
              onChanged: (v) => setState(() => _selectedGrade = v),
            ),
            const SizedBox(height: 16),

            // ── Parent/Guardian Email ──────────────────────────────────────
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
                    "If the guardian has an AOD account, they will be linked "
                    "and can see this player's view",
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
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone || isActive
                      ? cs.primary
                      : cs.surfaceContainerHighest,
                ),
                child: Center(
                  child: isDone
                      ? const Icon(Icons.check,
                          size: 16, color: Colors.white)
                      : Text(
                          '$step',
                          style: TextStyle(
                            color: isActive
                                ? Colors.white
                                : cs.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                ),
              ),
              if (i < total - 1)
                Expanded(
                  child: Container(
                    height: 2,
                    color: isDone ? cs.primary : cs.surfaceContainerHighest,
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }
}