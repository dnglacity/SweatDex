import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

// =============================================================================
// auth_service.dart  (AOD v1.8 — Efficiency Rebuild)
//
// CHANGES (Notes.txt — "make Supabase integration more efficient"):
//
//   1. signUp() — removed the _updateUserRowWithRetry() polling loop.
//      The new DB trigger (handle_new_user) runs SECURITY DEFINER with
//      SET search_path = public and is reliably fast.  Organisation and
//      athlete_id are now passed as raw_user_meta_data at sign-up time;
//      the trigger reads them and writes them directly to public.users.
//      This eliminates the 300 ms × 5 retry loop that previously ran on
//      every sign-up.
//
//   2. updateProfile() — no change needed; already optimal.
//
//   3. changeEmail() — the re-sign-in step is kept (required for Supabase
//      password verification pattern).  No other changes.
//
//   4. deleteAccount() — calls the RPC which handles all DB work atomically;
//      no change needed.
//
//   5. Removed _updateUserRowWithRetry() and all associated constants.
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
  /// CHANGE (v1.8): organisation and athlete_id are embedded in
  /// raw_user_meta_data at sign-up time.  The handle_new_user DB trigger
  /// (SECURITY DEFINER) reads them and writes them to public.users
  /// immediately — no follow-up UPDATE or retry loop needed.
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
        'last_name':  lastName,
        // Keep combined name for any legacy consumers.
        'name': '${firstName.trim()} ${lastName.trim()}'.trim(),
        if (organization != null && organization.isNotEmpty)
          'organization': organization,
        if (athleteId != null && athleteId.isNotEmpty)
          'athlete_id': athleteId,
      },
    );

    // CHANGE: No post-sign-up update call needed.  The DB trigger (Section 7
    // of supabase_migration.sql) handles creating the public.users row with
    // all fields from raw_user_meta_data in a single SECURITY DEFINER INSERT.
    return response;
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
      // OPTIMIZATION: explicit column list reduces payload.
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
  /// Accepts any subset of: firstName, lastName, nickname, organization, athleteId.
  /// NOTE: email changes must use changeEmail() — it is intentionally excluded.
  Future<void> updateProfile({
    String? firstName,
    String? lastName,
    String? nickname,
    String? organization,
    String? athleteId,
  }) async {
    final authUser = currentUser;
    if (authUser == null) throw Exception('Not logged in.');

    // OPTIMIZATION: only build the map for fields that were actually supplied,
    // so we don't send null values or overwrite data unnecessarily.
    final updates = <String, dynamic>{};
    if (firstName     != null) updates['first_name']   = firstName;
    if (lastName      != null) updates['last_name']    = lastName;
    if (nickname      != null) updates['nickname']     = nickname;
    if (organization  != null) updates['organization'] = organization;
    if (athleteId     != null) updates['athlete_id']   = athleteId;

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
  /// Throws a user-readable Exception on any failure so the UI can display it.
  Future<void> changeEmail({
    required String currentPassword,
    required String newEmail,
  }) async {
    final authUser = currentUser;
    if (authUser == null) throw Exception('Not logged in.');
    if (authUser.email == null) throw Exception('Current email not found.');

    // Step 1: verify current password by re-signing in.
    try {
      await _supabase.auth.signInWithPassword(
        email:    authUser.email!,
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

    // Step 2: cascade the change across public tables via SECURITY DEFINER RPC.
    try {
      await _supabase.rpc('change_user_email', params: {
        'p_old_email': oldEmail,
        'p_new_email': cleanNew,
      });
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('already in use') || msg.contains('already registered')) {
        throw Exception('That email address is already in use by another account.');
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