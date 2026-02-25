import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

// =============================================================================
// auth_service.dart  (AOD v1.11 — Review Rebuild)
//
// CHANGES vs v1.8:
//
//   AUTH-1: deleteAccount() now catches AuthSessionMissingException
//     that can be thrown by signOut() when the session is already gone
//     after the RPC deletes the auth.users row. The session is effectively
//     ended either way, so we swallow this specific error.
//
//   AUTH-2: signOut() is now guarded against the same
//     AuthSessionMissingException for the same reason.
//
//   AUTH-3: changeEmail() now trims and lowercases the newEmail BEFORE the
//     re-auth call so the comparison against authUser.email is always
//     case-insensitive and whitespace-safe.
//
//   AUTH-4: updateProfile() now accepts a boolean `clearNickname` param so
//     a caller can explicitly set nickname to null (empty string → null) via
//     the account settings screen without passing a null that gets silently
//     skipped by the existing "if (nickname != null)" guard.
//
//   MAINT-1: Consistent use of debugPrint for all caught exceptions.
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
  /// organisation and athlete_id are embedded in raw_user_meta_data.
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
    return response;
  }

  // ── Sign In ───────────────────────────────────────────────────────────────

  /// Signs in with email and password.
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    return await _supabase.auth.signInWithPassword(
      email: email.trim().toLowerCase(),
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

    // clearNickname = true → explicitly write null to the column.
    // clearNickname = false + nickname != null → write the value.
    // clearNickname = false + nickname == null → skip (no change).
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

    // AUTH-3: normalise both sides of the comparison.
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
      throw Exception('Current password is incorrect. Please try again.');
    }

    // Step 2: cascade the change across public tables via SECURITY DEFINER RPC.
    try {
      await _supabase.rpc('change_user_email', params: {
        'p_old_email': oldEmail,
        'p_new_email': cleanNew,
      });
    } catch (e) {
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
      // Re-throw unless it's the expected session-already-gone case.
      if (e is! AuthSessionMissingException) rethrow;
    }
    try {
      await _supabase.auth.signOut();
    } on AuthSessionMissingException {
      // AUTH-1: session was already invalidated by the RPC — ignore.
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
      // AUTH-2: already signed out — no action needed.
      debugPrint('signOut: no active session.');
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