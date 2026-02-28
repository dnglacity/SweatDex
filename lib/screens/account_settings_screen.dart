import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../services/auth_service.dart';
import '../services/player_service.dart';

// =============================================================================
// account_settings_screen.dart  (AOD v1.7 — updated)
//
// CHANGE (Notes.txt v1.7 — Email Change):
//   • Email field is now READ-ONLY in the main profile form.
//   • An "Edit" icon button appears next to the email field at all times.
//   • Tapping it opens _showEmailChangeDialog(), which:
//       1. Asks for the current password (hidden, toggleable).
//       2. Asks for the new email entered TWICE for confirmation.
//       3. Validates both entries match and the format is valid.
//       4. Calls authService.changeEmail(), which:
//            – Re-authenticates to verify the password.
//            – Calls the `change_user_email` SECURITY DEFINER RPC to cascade
//              the change across public.users, players.athlete_email, and
//              players.guardian_email in a single transaction.
//            – Updates the Supabase Auth email (triggers re-verification).
//       5. Shows a confirmation snackbar and reloads the profile.
//
// All other v1.7 behaviours retained:
//   – First/Last/Nickname editing
//   – Delete account with acknowledgement checkbox
//   – Profile avatar with initial letter
// =============================================================================

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  final _authService = AuthService();
  final _playerService = PlayerService();

  // Profile loaded from Supabase.
  AppUser? _user;
  bool _loading = true;
  String? _errorMessage;

  // Editing state for name/nickname fields only.
  bool _isEditing = false;
  bool _isSaving = false;

  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _nicknameController = TextEditingController();
  // NOTE: _emailController is display-only. Editing goes through the
  // _showEmailChangeDialog flow.
  final _emailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _nicknameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  // ── Load profile ──────────────────────────────────────────────────────────

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final profile = await _playerService.getCurrentUser();
      if (profile == null) throw Exception('Profile not found.');

      final user = AppUser.fromMap(profile);
      setState(() {
        _user = user;
        _loading = false;
      });
      _populateControllers(user);
    } catch (e) {
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  void _populateControllers(AppUser user) {
    _firstNameController.text = user.firstName;
    _lastNameController.text = user.lastName;
    _nicknameController.text = user.nickname ?? '';
    // Email is read-only; controller is only used for display.
    _emailController.text = user.email;
  }

  // ── Save profile (name/nickname only) ─────────────────────────────────────

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      await _authService.updateProfile(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        nickname: _nicknameController.text.trim().isEmpty
            ? null
            : _nicknameController.text.trim(),
      );

      await _loadProfile();
      setState(() => _isEditing = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Email Change Dialog (Notes.txt — password-gated, double-entry) ─────────
  //
  // This dialog:
  //   1. Requires the current password for verification.
  //   2. Requires typing the new email TWICE to confirm.
  //   3. Validates format on both fields.
  //   4. Calls authService.changeEmail() which re-auths, then cascades the
  //      change across the DB + Supabase Auth.

  Future<void> _showEmailChangeDialog() async {
    final passwordController = TextEditingController();
    final email1Controller = TextEditingController();
    final email2Controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool obscurePassword = true;
    bool isSubmitting = false;
    String? dialogError;

    await showDialog<void>(
      context: context,
      barrierDismissible: false, // require explicit cancel
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Change Email'),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Informational note ──────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Your email is used to log in. After changing it, '
                      'you may need to verify the new address before signing '
                      'in again.\n\nThis will update your email everywhere in '
                      'the app (player records, guardian links, etc.).',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Current password ────────────────────────────────────
                  Text(
                    'Current Password',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700],
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      hintText: 'Enter your current password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      // Toggle password visibility.
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                        onPressed: () =>
                            setLocal(() => obscurePassword = !obscurePassword),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return 'Please enter your current password';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),

                  // ── New email (first entry) ──────────────────────────────
                  Text(
                    'New Email Address',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700],
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: email1Controller,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'new@example.com',
                      prefixIcon: Icon(Icons.email_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Please enter the new email';
                      }
                      if (!v.contains('@') || !v.contains('.')) {
                        return 'Enter a valid email address';
                      }
                      final current = _user?.email.toLowerCase().trim() ?? '';
                      if (v.trim().toLowerCase() == current) {
                        return 'New email must be different from current email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // ── New email (confirmation entry) ───────────────────────
                  Text(
                    'Confirm New Email Address',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[700],
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: email2Controller,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'Retype new email to confirm',
                      prefixIcon: Icon(Icons.email),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Please confirm the new email';
                      }
                      if (v.trim().toLowerCase() !=
                          email1Controller.text.trim().toLowerCase()) {
                        return 'Email addresses do not match';
                      }
                      return null;
                    },
                  ),

                  // ── Inline error from the service call ───────────────────
                  if (dialogError != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withOpacity(0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.red, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              dialogError!,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            // Cancel button — always enabled.
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            // Confirm button — disabled while submitting.
            FilledButton(
              onPressed: isSubmitting
                  ? null
                  : () async {
                      // Clear previous inline error.
                      setLocal(() => dialogError = null);

                      if (!formKey.currentState!.validate()) return;

                      setLocal(() => isSubmitting = true);

                      try {
                        await _authService.changeEmail(
                          currentPassword: passwordController.text,
                          newEmail: email1Controller.text.trim(),
                        );

                        // Close dialog on success.
                        if (ctx.mounted) Navigator.pop(ctx);

                        // Reload profile to show new email.
                        await _loadProfile();

                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Email updated! Check your inbox to verify '
                                'the new address.',
                              ),
                              backgroundColor: Colors.green,
                              duration: Duration(seconds: 6),
                            ),
                          );
                        }
                      } catch (e) {
                        // Show the error inline inside the dialog (not a
                        // snackbar) so the user can correct and retry without
                        // re-opening the dialog.
                        setLocal(() {
                          isSubmitting = false;
                          dialogError = e
                              .toString()
                              .replaceAll('Exception: ', '');
                        });
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2),
                    )
                  : const Text('Change Email'),
            ),
          ],
        ),
      ),
    );

    // Deferred disposal — prevents "controller used after dispose" on
    // the dialog close animation frame (same pattern as other dialogs).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      passwordController.dispose();
      email1Controller.dispose();
      email2Controller.dispose();
    });
  }

  // ── Delete account ────────────────────────────────────────────────────────

  Future<void> _showDeleteAccountDialog() async {
    bool acknowledged = false;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Delete Account'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This will permanently delete your Apex On Deck account. '
                'All your team memberships will be removed.\n\n'
                'If you are the sole owner of any team, you must transfer '
                'ownership or delete that team first.',
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: acknowledged,
                    activeColor: Colors.red,
                    onChanged: (v) =>
                        setLocal(() => acknowledged = v ?? false),
                  ),
                  const Expanded(
                    child: Text(
                      'I understand this action is permanent and cannot be undone.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  acknowledged ? () => Navigator.pop(ctx, true) : null,
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete My Account'),
            ),
          ],
        ),
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await _authService.deleteAccount();
      // AuthWrapper routes to LoginScreen when the session is cleared.
    } catch (e) {
      if (mounted) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cannot Delete Account'),
            content: Text(e.toString().replaceAll('Exception: ', '')),
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
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account Settings'),
        centerTitle: true,
        actions: [
          if (!_loading && _errorMessage == null && !_isEditing)
            TextButton(
              onPressed: () => setState(() => _isEditing = true),
              child:
                  const Text('Edit', style: TextStyle(color: Colors.white)),
            ),
          if (_isEditing)
            TextButton(
              onPressed: () {
                setState(() => _isEditing = false);
                if (_user != null) _populateControllers(_user!);
              },
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? _buildError()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Avatar / greeting ────────────────────────────────
                      Center(
                        child: CircleAvatar(
                          radius: 40,
                          backgroundColor: cs.primaryContainer,
                          child: Text(
                            _user?.firstName.isNotEmpty == true
                                ? _user!.firstName[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          _user?.name ?? '',
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      if (_user?.nickname != null &&
                          _user!.nickname!.isNotEmpty)
                        Center(
                          child: Text(
                            '"${_user!.nickname}"',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontStyle: FontStyle.italic,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      const SizedBox(height: 32),

                      // ── Profile form ──────────────────────────────────────
                      Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // First Name
                            _buildField(
                              controller: _firstNameController,
                              label: 'First Name',
                              icon: Icons.person_outline,
                              enabled: _isEditing,
                              validator: (v) =>
                                  (v == null || v.trim().isEmpty)
                                      ? 'Required'
                                      : null,
                            ),
                            const SizedBox(height: 16),

                            // Last Name
                            _buildField(
                              controller: _lastNameController,
                              label: 'Last Name',
                              icon: Icons.person,
                              enabled: _isEditing,
                              validator: (v) =>
                                  (v == null || v.trim().isEmpty)
                                      ? 'Required'
                                      : null,
                            ),
                            const SizedBox(height: 16),

                            // Nickname
                            _buildField(
                              controller: _nicknameController,
                              label: 'Default Nickname (optional)',
                              icon: Icons.badge,
                              enabled: _isEditing,
                              helperText:
                                  'Coaches can override this on their roster',
                            ),
                            const SizedBox(height: 16),

                            // ── Email — read-only with edit button ──────────
                            // CHANGE (Notes.txt): email is never editable inline.
                            // The pencil icon launches the password-gated flow.
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _emailController,
                                    enabled: false, // always read-only
                                    keyboardType: TextInputType.emailAddress,
                                    decoration: InputDecoration(
                                      labelText: 'Email',
                                      prefixIcon:
                                          const Icon(Icons.email),
                                      border: const OutlineInputBorder(),
                                      filled: true,
                                      fillColor:
                                          Colors.grey.withOpacity(0.05),
                                      // Lock icon reinforces read-only state.
                                      suffixIcon: const Icon(
                                          Icons.lock_outline,
                                          size: 16,
                                          color: Colors.grey),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Edit button — always visible regardless of
                                // whether the rest of the form is in edit mode.
                                Tooltip(
                                  message: 'Change Email',
                                  child: IconButton(
                                    icon: const Icon(Icons.edit,
                                        color: Colors.blue),
                                    onPressed: _showEmailChangeDialog,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // ── Save button ───────────────────────────────────────
                      if (_isEditing) ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 50,
                          child: FilledButton(
                            onPressed: _isSaving ? null : _saveProfile,
                            child: _isSaving
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 2),
                                  )
                                : const Text('Save Changes',
                                    style: TextStyle(fontSize: 16)),
                          ),
                        ),
                      ],

                      // ── Danger zone ───────────────────────────────────────
                      const SizedBox(height: 48),
                      const Divider(),
                      const SizedBox(height: 16),
                      Text(
                        'Danger Zone',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _showDeleteAccountDialog,
                        icon: const Icon(Icons.delete_forever,
                            color: Colors.red),
                        label: const Text('Delete Account',
                            style: TextStyle(color: Colors.red)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red),
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'If you are the sole owner of any team, you must '
                        'transfer ownership or delete the team before deleting '
                        'your account.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.grey[600]),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
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
            onPressed: _loadProfile,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  // ── Field builder ─────────────────────────────────────────────────────────

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool enabled = true,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    String? helperText,
  }) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      textCapitalization: TextCapitalization.words,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
        filled: !enabled,
        fillColor: enabled ? null : Colors.grey.withOpacity(0.05),
        helperText: helperText,
      ),
      validator: validator,
    );
  }
}