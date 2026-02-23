import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

// =============================================================================
// auth_service.dart  (AOD v1.7 — updated)
//
// CHANGE (Notes.txt v1.7 — Email Change):
//   • changeEmail() — new method. Password-verifies the current user, then
//     calls the `change_user_email` SECURITY DEFINER RPC which cascades the
//     new email across:
//       – public.users.email
//       – players.athlete_email  (where athlete_email = old email)
//       – players.guardian_email (where guardian_email = old email)
//     After the DB update, calls Supabase Auth updateUser() to change the
//     login email in auth.users.
//
// All prior v1.7 methods retained unchanged:
//   signUp, signIn, updateProfile, deleteAccount, signOut, resetPassword
// =============================================================================

class AuthService {
  final _supabase = Supabase.instance.client;

  // ── Getters ───────────────────────────────────────────────────────────────

  /// The currently authenticated Supabase auth user, or null if not signed in.
  User? get currentUser => _supabase.auth.currentUser;

  /// True when a user is currently signed in.
  bool get isLoggedIn => currentUser != null;

  // ── Sign Up ───────────────────────────────────────────────────────────────

  /// Creates a new auth user.
  /// CHANGE (v1.7): accepts firstName / lastName instead of name.
  /// athleteId is optional.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    String? organization,
    String? athleteId,
  }) async {
    final response = await _supabase.auth.signUp(
      email: email,
      password: password,
      data: {
        'first_name': firstName,
        'last_name': lastName,
        // Keep combined `name` so existing DB trigger still populates name col.
        'name': '${firstName.trim()} ${lastName.trim()}'.trim(),
        if (organization != null && organization.isNotEmpty)
          'organization': organization,
        if (athleteId != null && athleteId.isNotEmpty) 'athlete_id': athleteId,
      },
    );

    // Update organization / athlete_id after the trigger creates the users row.
    if (response.user != null) {
      final updates = <String, dynamic>{};
      if (organization != null && organization.isNotEmpty) {
        updates['organization'] = organization;
      }
      if (athleteId != null && athleteId.isNotEmpty) {
        updates['athlete_id'] = athleteId;
      }
      if (updates.isNotEmpty) {
        await _updateUserRowWithRetry(response.user!.id, updates);
      }
    }

    return response;
  }

  // ── Retry helper ──────────────────────────────────────────────────────────

  static const int _maxTriggerRetries = 5;
  static const Duration _triggerRetryDelay = Duration(milliseconds: 300);

  /// Polls until the `users` row for [authUserId] exists, then writes [fields].
  /// Needed because the on_auth_user_created trigger commits asynchronously.
  Future<void> _updateUserRowWithRetry(
      String authUserId, Map<String, dynamic> fields) async {
    for (int attempt = 1; attempt <= _maxTriggerRetries; attempt++) {
      await Future.delayed(_triggerRetryDelay);
      try {
        final existing = await _supabase
            .from('users')
            .select('id')
            .eq('user_id', authUserId)
            .maybeSingle();

        if (existing != null) {
          await _supabase
              .from('users')
              .update(fields)
              .eq('user_id', authUserId);
          return;
        }
      } catch (e) {
        debugPrint('⚠️ User row update attempt $attempt failed: $e');
      }
    }
    debugPrint(
        '⚠️ Could not update user row after $_maxTriggerRetries attempts.');
  }

  // ── Sign In ───────────────────────────────────────────────────────────────

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    return await _supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  // ── Profile ───────────────────────────────────────────────────────────────

  /// Returns the raw `users` map for the currently signed-in user, or null.
  Future<Map<String, dynamic>?> getCurrentUserProfile() async {
    try {
      final authUser = currentUser;
      if (authUser == null) return null;
      return await _supabase
          .from('users')
          .select()
          .eq('user_id', authUser.id)
          .single();
    } catch (e) {
      debugPrint('Get user profile error: $e');
      return null;
    }
  }

  /// Updates the user's profile fields in public.users.
  /// Accepts any subset of: firstName, lastName, nickname, organization, athleteId.
  /// NOTE: email is intentionally excluded — use changeEmail() instead.
  Future<void> updateProfile({
    String? firstName,
    String? lastName,
    String? nickname,
    String? organization,
    String? athleteId,
  }) async {
    final authUser = currentUser;
    if (authUser == null) throw Exception('Not logged in.');

    final updates = <String, dynamic>{};
    if (firstName != null) updates['first_name'] = firstName;
    if (lastName != null) updates['last_name'] = lastName;
    if (nickname != null) updates['nickname'] = nickname;
    if (organization != null) updates['organization'] = organization;
    if (athleteId != null) updates['athlete_id'] = athleteId;

    if (updates.isEmpty) return;

    await _supabase.from('users').update(updates).eq('user_id', authUser.id);
  }

  // ── Change Email (NEW — Notes.txt v1.7) ──────────────────────────────────

  /// Changes the current user's email address everywhere in the database.
  ///
  /// FLOW:
  ///   1. Re-authenticates with [currentPassword] to verify identity.
  ///   2. Calls the `change_user_email` SECURITY DEFINER RPC which atomically:
  ///        – Updates public.users.email
  ///        – Updates players.athlete_email where it matches the old email
  ///        – Updates players.guardian_email where it matches the old email
  ///   3. Calls Supabase Auth updateUser() to change the login email.
  ///
  /// Throws a user-readable Exception on any failure so the UI can display it.
  Future<void> changeEmail({
    required String currentPassword,
    required String newEmail,
  }) async {
    final authUser = currentUser;
    if (authUser == null) throw Exception('Not logged in.');
    if (authUser.email == null) throw Exception('Current email not found.');

    // Step 1 — verify current password by re-signing in.
    // Supabase does not have a standalone "verify password" endpoint;
    // re-signing in with email+password is the standard pattern.
    try {
      await _supabase.auth.signInWithPassword(
        email: authUser.email!,
        password: currentPassword,
      );
    } catch (e) {
      throw Exception('Current password is incorrect. Please try again.');
    }

    final oldEmail = authUser.email!.toLowerCase().trim();
    final cleanNew = newEmail.toLowerCase().trim();

    if (oldEmail == cleanNew) {
      throw Exception('New email is the same as the current email.');
    }

    // Step 2 — cascade the email change across public tables via SECURITY
    // DEFINER RPC (bypasses RLS so all rows are updated even if they belong
    // to players on other teams).
    try {
      await _supabase.rpc('change_user_email', params: {
        'p_old_email': oldEmail,
        'p_new_email': cleanNew,
      });
    } catch (e) {
      // Surface the DB-level error (e.g. email already in use).
      final msg = e.toString();
      if (msg.contains('already in use') || msg.contains('already registered')) {
        throw Exception('That email address is already in use by another account.');
      }
      throw Exception('Database update failed: $msg');
    }

    // Step 3 — update the email in Supabase Auth (triggers confirmation email).
    try {
      await _supabase.auth.updateUser(UserAttributes(email: cleanNew));
    } catch (e) {
      // The DB has already been updated; surface the auth error so user knows
      // they may need to re-verify.
      throw Exception(
          'Profile updated but auth email change failed. '
          'Please contact support. Details: $e');
    }
  }

  // ── Delete Account ────────────────────────────────────────────────────────

  /// Deletes the current user's account via SECURITY DEFINER RPC.
  /// Blocked if the user is the sole owner of any team.
  Future<void> deleteAccount() async {
    await _supabase.rpc('delete_account');
    await _supabase.auth.signOut();
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    await _supabase.auth.signOut();
  }

  // ── Password Reset ────────────────────────────────────────────────────────

  Future<void> resetPassword(String email) async {
    await _supabase.auth.resetPasswordForEmail(email);
  }

  // ── Auth State Stream ─────────────────────────────────────────────────────

  Stream<AuthState> get authStateChanges => _supabase.auth.onAuthStateChange;
}