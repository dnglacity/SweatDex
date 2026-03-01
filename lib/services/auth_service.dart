import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

// =============================================================================
// auth_service.dart  (AOD v1.12 — BUG FIX: database connection error)
//
// FIXES (AI_TODO_List.md — "Review and fix database connection issue"):
//
//   FIX-1: signUp() and signIn() now have try/catch blocks that debugPrint
//     the raw exception before re-throwing. Previously both methods had NO
//     error handling — exceptions propagated raw to login_screen which only
//     logged them IF login_screen's own catch block ran (which it didn't
//     always, due to FIX-1 in login_screen.dart).
//
//   FIX-2: signUp() validates that the returned AuthResponse.user is not
//     null and throws a typed exception if it is, giving login_screen's
//     _getErrorMessage() a reliable string to match against ('null_user').
//     Supabase can return HTTP 200 with user==null when the handle_new_user
//     DB trigger fails silently or an email rate-limit is hit.
//
//   FIX-3: signIn() now logs the error with the email (redacted to domain
//     only for privacy) so failed logins are traceable in the console
//     without exposing the full address.
//
// All v1.11 behaviours retained:
//   – AUTH-1 through AUTH-4 fixes
//   – deleteAccount(), signOut(), changeEmail(), updateProfile()
//   – Consistent debugPrint for all caught exceptions
// =============================================================================

class AuthService {
  final _supabase = Supabase.instance.client;

  // ── Getters ───────────────────────────────────────────────────────────────

  /// The currently authenticated Supabase auth user, or null if not signed in.
  User? get currentUser => _supabase.auth.currentUser;

  /// True when a user is currently signed in.
  bool get isLoggedIn => currentUser != null;

  // ── Sign Up ───────────────────────────────────────────────────────────────

  /// Creates a new auth user and public profile.
  ///
  /// FIX-1: Wrapped in try/catch so the raw Supabase error is always logged.
  /// FIX-2: Validates response.user != null. If null, throws a typed exception
  ///   so login_screen._getErrorMessage() can show a specific message.
  ///
  /// Organisation and athlete_id are embedded in raw_user_meta_data.
  /// The handle_new_user DB trigger reads them and writes them to
  /// public.users immediately — no follow-up UPDATE or retry loop needed.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    String? organization,
    String? athleteId,
  }) async {
    try {
      final response = await _supabase.auth.signUp(
        email: email.trim().toLowerCase(),
        password: password,
        data: {
          'first_name': firstName.trim(),
          'last_name':  lastName.trim(),
          // Combined name kept for any legacy consumers (e.g. old DB rows).
          'name': '${firstName.trim()} ${lastName.trim()}'.trim(),
          if (organization != null && organization.isNotEmpty)
            'organization': organization.trim(),
          if (athleteId != null && athleteId.isNotEmpty)
            'athlete_id': athleteId.trim(),
        },
      );

      // FIX-2: Supabase returns HTTP 200 with user==null in some failure
      // scenarios (handle_new_user trigger error, silent rate-limit).
      // Previously this was not checked and login_screen showed a false
      // success message.
      if (response.user == null) {
        debugPrint(
          'AuthService.signUp: response.user is null for email domain '
          '${email.split('@').lastOrNull ?? 'unknown'}. '
          'Possible handle_new_user trigger failure or rate limit.',
        );
        throw Exception(
          'null_user: Account could not be created. '
          'Please try again or contact support.',
        );
      }

      return response;
    } catch (e) {
      // FIX-1: Always log the raw error. Re-throw so login_screen can
      // map it to a user-friendly message via _getErrorMessage().
      debugPrint('AuthService.signUp error: $e');
      rethrow;
    }
  }

  // ── Sign In ───────────────────────────────────────────────────────────────

  /// Signs in with email and password.
  ///
  /// FIX-1: Wrapped in try/catch so the raw Supabase error is always logged.
  /// FIX-3: Logs the email domain only (not the full address) for privacy.
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    try {
      return await _supabase.auth.signInWithPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );
    } catch (e) {
      // FIX-1 / FIX-3: Log domain only — never log the full email address.
      final domain = email.contains('@') ? email.split('@').last : 'unknown';
      debugPrint('AuthService.signIn error (domain: $domain): $e');
      rethrow;
    }
  }

  // ── Profile ───────────────────────────────────────────────────────────────

  /// Returns the raw `users` map for the currently signed-in user, or null.
  Future<Map<String, dynamic>?> getCurrentUserProfile() async {
    try {
      final authUser = currentUser;
      if (authUser == null) return null;
      return await _supabase
          .from('users')
          .select(
            'id, user_id, first_name, last_name, nickname, athlete_id, '
            'email, organization, created_at',
          )
          .eq('user_id', authUser.id)
          .single();
    } catch (e) {
      debugPrint('getCurrentUserProfile error: $e');
      return null;
    }
  }

  /// Updates the user's profile fields in public.users.
  ///
  /// Only supplied (non-null) fields are sent in the UPDATE — the existing
  /// row values for other fields are preserved.
  ///
  /// AUTH-4: [clearNickname] = true explicitly sets nickname = null so
  /// the user can remove a nickname they previously set. This bypasses the
  /// "if (nickname != null)" guard that would otherwise skip the update.
  Future<void> updateProfile({
    String? firstName,
    String? lastName,
    String? nickname,
    bool clearNickname = false,
    String? organization,
    String? athleteId,
  }) async {
    final authUser = currentUser;
    if (authUser == null) throw Exception('Not logged in.');

    final updates = <String, dynamic>{};
    if (firstName    != null) updates['first_name']   = firstName.trim();
    if (lastName     != null) updates['last_name']    = lastName.trim();

    if (clearNickname) {
      updates['nickname'] = null;
    } else if (nickname != null) {
      updates['nickname'] = nickname.isEmpty ? null : nickname.trim();
    }

    if (organization != null) updates['organization'] = organization.trim();
    if (athleteId    != null) updates['athlete_id']   = athleteId.trim();

    if (updates.isEmpty) return;

    await _supabase.from('users').update(updates).eq('user_id', authUser.id);
  }

  // ── Change Email ──────────────────────────────────────────────────────────

  /// Changes the current user's email address everywhere in the database.
  ///
  /// FLOW:
  ///   1. Re-authenticates with [currentPassword] to verify identity.
  ///   2. Calls the change_user_email SECURITY DEFINER RPC which atomically:
  ///        – Updates public.users.email
  ///        – Updates players.athlete_email where it matches the old email
  ///        – Updates players.guardian_email where it matches the old email
  ///   3. Calls Supabase Auth updateUser() to change the login email.
  ///
  /// AUTH-3: newEmail is normalised (trim + lowercase) before comparison.
  Future<void> changeEmail({
    required String currentPassword,
    required String newEmail,
  }) async {
    final authUser = currentUser;
    if (authUser == null) throw Exception('Not logged in.');
    if (authUser.email == null) throw Exception('Current email not found.');

    final oldEmail = authUser.email!.toLowerCase().trim();
    final cleanNew = newEmail.toLowerCase().trim();

    if (oldEmail == cleanNew) {
      throw Exception('New email is the same as the current email.');
    }

    // Step 1: verify current password by re-signing in.
    try {
      await _supabase.auth.signInWithPassword(
        email:    oldEmail,
        password: currentPassword,
      );
    } catch (e) {
      debugPrint('changeEmail re-auth error: $e');
      throw Exception('Current password is incorrect. Please try again.');
    }

    // Step 2: cascade the change across public tables via SECURITY DEFINER RPC.
    try {
      await _supabase.rpc('change_user_email', params: {
        'p_old_email': oldEmail,
        'p_new_email': cleanNew,
      });
    } catch (e) {
      debugPrint('changeEmail RPC error: $e');
      final msg = e.toString();
      if (msg.contains('already in use') || msg.contains('already registered')) {
        throw Exception(
            'That email address is already in use by another account.');
      }
      throw Exception('Database update failed: $msg');
    }

    // Step 3: update the email in Supabase Auth (triggers confirmation email).
    try {
      await _supabase.auth.updateUser(UserAttributes(email: cleanNew));
    } catch (e) {
      debugPrint('changeEmail auth updateUser error: $e');
      throw Exception(
        'Profile updated but auth email change failed. '
        'Please contact support. Details: $e',
      );
    }
  }

  // ── Delete Account ────────────────────────────────────────────────────────

  /// Deletes the current user's account via the delete_account SECURITY
  /// DEFINER RPC, then signs out.
  ///
  /// AUTH-1: AuthSessionMissingException from signOut() is swallowed because
  /// the RPC may have already invalidated the session by deleting the
  /// auth.users row — the user is effectively signed out either way.
  Future<void> deleteAccount() async {
    try {
      await _supabase.rpc('delete_account');
    } catch (e) {
      if (e is! AuthSessionMissingException) rethrow;
    }
    try {
      await _supabase.auth.signOut();
    } on AuthSessionMissingException {
      debugPrint('deleteAccount: session already gone after RPC, ignoring.');
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  /// Signs the current user out.
  ///
  /// AUTH-2: AuthSessionMissingException is swallowed — if the session
  /// is already gone (e.g. token expired), the user is effectively signed out.
  Future<void> signOut() async {
    try {
      await _supabase.auth.signOut();
    } on AuthSessionMissingException {
      debugPrint('signOut: no active session.');
    }
  }

  // ── Change Password ───────────────────────────────────────────────────────

  /// Changes the current user's password after verifying [currentPassword].
  ///
  /// FLOW:
  ///   1. Re-authenticates with [currentPassword] to verify identity.
  ///   2. Calls Supabase Auth updateUser() to set [newPassword].
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final authUser = currentUser;
    if (authUser == null) throw Exception('Not logged in.');
    if (authUser.email == null) throw Exception('Current email not found.');

    // Step 1: verify current password by re-signing in.
    try {
      await _supabase.auth.signInWithPassword(
        email: authUser.email!.toLowerCase().trim(),
        password: currentPassword,
      );
    } catch (e) {
      debugPrint('changePassword re-auth error: $e');
      throw Exception('Current password is incorrect. Please try again.');
    }

    // Step 2: update the password in Supabase Auth.
    try {
      await _supabase.auth.updateUser(UserAttributes(password: newPassword));
    } catch (e) {
      debugPrint('changePassword updateUser error: $e');
      throw Exception('Password update failed. Please try again.');
    }
  }

  // ── Password Reset ────────────────────────────────────────────────────────

  /// Sends a password reset email to [email].
  Future<void> resetPassword(String email) async {
    await _supabase.auth.resetPasswordForEmail(
      email.trim().toLowerCase(),
    );
  }

  // ── Auth State Stream ─────────────────────────────────────────────────────

  /// Emits [AuthState] events for the lifetime of the app.
  Stream<AuthState> get authStateChanges => _supabase.auth.onAuthStateChange;
}