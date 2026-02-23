import 'package:flutter/material.dart';
import '../models/app_user.dart';
import '../services/auth_service.dart';
import '../services/player_service.dart';
import 'login_screen.dart';

// =============================================================================
// account_settings_screen.dart  (AOD v1.7 — NEW)
//
// CHANGE (Notes.txt v1.7):
//   • New screen accessible from the options menu (persistent, always visible).
//   • Allows the user to edit:
//       – First Name
//       – Last Name
//       – Default Nickname (optional; coaches can override locally on roster)
//       – Email
//   • Delete Account option with:
//       – Confirmation dialog with checkbox
//       – Blocked if the user is the sole owner of any team (RPC enforces this)
//       – Friendly error shown with instructions to transfer or delete team first
// =============================================================================

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  final _authService   = AuthService();
  final _playerService = PlayerService();

  // Profile data loaded from Supabase.
  AppUser? _user;
  bool _loading = true;
  String? _errorMessage;

  // Editing state.
  bool _isEditing = false;
  bool _isSaving  = false;

  final _formKey            = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController  = TextEditingController();
  final _nicknameController  = TextEditingController();
  final _emailController     = TextEditingController();

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
      _loading      = true;
      _errorMessage = null;
    });
    try {
      final profile = await _playerService.getCurrentUser();
      if (profile == null) throw Exception('Profile not found.');

      final user = AppUser.fromMap(profile);
      setState(() {
        _user     = user;
        _loading  = false;
      });
      _populateControllers(user);
    } catch (e) {
      setState(() {
        _loading      = false;
        _errorMessage = e.toString();
      });
    }
  }

  void _populateControllers(AppUser user) {
    _firstNameController.text = user.firstName;
    _lastNameController.text  = user.lastName;
    _nicknameController.text  = user.nickname ?? '';
    _emailController.text     = user.email;
  }

  // ── Save profile ──────────────────────────────────────────────────────────

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    try {
      await _authService.updateProfile(
        firstName:    _firstNameController.text.trim(),
        lastName:     _lastNameController.text.trim(),
        nickname:     _nicknameController.text.trim().isEmpty
                        ? null
                        : _nicknameController.text.trim(),
        email:        _emailController.text.trim(),
      );

      // Reload to show the saved state.
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
              onPressed: acknowledged
                  ? () => Navigator.pop(ctx, true)
                  : null,
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete My Account'),
            ),
          ],
        ),
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      // delete_account() RPC blocks if user is sole owner of a team.
      await _authService.deleteAccount();

      if (mounted) {
        // Navigate to login — account is gone.
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        // Show the friendly error from the RPC (e.g. sole owner message).
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cannot Delete Account'),
            content: Text(
              e.toString().replaceAll('Exception: ', ''),
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
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account Settings'),
        centerTitle: true,
        actions: [
          if (!_loading && _errorMessage == null && !_isEditing)
            TextButton(
              onPressed: () => setState(() => _isEditing = true),
              child: const Text('Edit',
                  style: TextStyle(color: Colors.white)),
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
                      // ── Avatar / greeting ─────────────────────────────────
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
                                color: cs.onSurfaceVariant),
                          ),
                        ),
                      const SizedBox(height: 32),

                      // ── Profile form ──────────────────────────────────────
                      Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
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
                            _buildField(
                              controller: _nicknameController,
                              label: 'Default Nickname (optional)',
                              icon: Icons.badge,
                              enabled: _isEditing,
                              helperText:
                                  'Coaches can override this on their roster',
                            ),
                            const SizedBox(height: 16),
                            _buildField(
                              controller: _emailController,
                              label: 'Email',
                              icon: Icons.email,
                              enabled: _isEditing,
                              keyboardType: TextInputType.emailAddress,
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return 'Required';
                                }
                                if (!v.contains('@')) {
                                  return 'Enter a valid email';
                                }
                                return null;
                              },
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