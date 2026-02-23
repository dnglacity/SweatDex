import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

// =============================================================================
// auth_service.dart  (AOD v1.7)
//
// CHANGE (Notes.txt v1.7):
//   • signUp() now accepts `firstName`, `lastName` (replaces `name`).
//     Passes both via raw_user_meta_data so the on_auth_user_created trigger
//     writes them to users.first_name and users.last_name.
//   • signUp() accepts optional `athleteId` — stored in users.athlete_id.
//   • deleteAccount() — calls the new delete_account() SECURITY DEFINER RPC,
//     then signs out. The RPC blocks deletion if the user is a sole team owner.
//   • updateProfile() — updates first_name, last_name, nickname, email in
//     the public.users row.
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
  ///
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
        'first_name':   firstName,
        'last_name':    lastName,
        // Keep a combined `name` in meta so the existing DB trigger still
        // populates the name column correctly.
        'name':         '${firstName.trim()} ${lastName.trim()}'.trim(),
        if (organization != null && organization.isNotEmpty)
          'organization': organization,
        if (athleteId != null && athleteId.isNotEmpty)
          'athlete_id': athleteId,
      },
    );

    // If extra fields were provided, update the users row after the trigger
    // creates it (organization + athlete_id may not be handled by the trigger).
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

  static const int      _maxTriggerRetries  = 5;
  static const Duration _triggerRetryDelay  = Duration(milliseconds: 300);

  /// Polls until the `users` row for [authUserId] exists, then writes [fields].
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
    debugPrint('⚠️ Could not update user row after $_maxTriggerRetries attempts.');
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
  ///
  /// CHANGE (v1.7): replaces the old organization-only update.
  /// Accepts any subset of: firstName, lastName, nickname, email.
  Future<void> updateProfile({
    String? firstName,
    String? lastName,
    String? nickname,
    String? email,
    String? organization,
    String? athleteId,
  }) async {
    final authUser = currentUser;
    if (authUser == null) throw Exception('Not logged in.');

    final updates = <String, dynamic>{};
    if (firstName    != null) updates['first_name']   = firstName;
    if (lastName     != null) updates['last_name']    = lastName;
    if (nickname     != null) updates['nickname']     = nickname;
    if (email        != null) updates['email']        = email;
    if (organization != null) updates['organization'] = organization;
    if (athleteId    != null) updates['athlete_id']   = athleteId;

    if (updates.isEmpty) return;

    await _supabase
        .from('users')
        .update(updates)
        .eq('user_id', authUser.id);

    // If email changed, also update it in Supabase Auth.
    if (email != null) {
      await _supabase.auth.updateUser(UserAttributes(email: email));
    }
  }

  // ── Delete Account ────────────────────────────────────────────────────────

  /// Deletes the current user's account.
  ///
  /// CHANGE (v1.7): Calls the `delete_account` SECURITY DEFINER RPC which
  /// blocks the deletion if the user is the sole owner of any team.
  /// On success, signs the user out locally.
  ///
  /// Throws an Exception with a user-readable message if blocked.
  Future<void> deleteAccount() async {
    // The RPC raises an exception with a message like
    // "You are the sole owner of 'Team Name'…" which we re-throw.
    await _supabase.rpc('delete_account');
    // Sign out after the public.users row is deleted.
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