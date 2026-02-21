import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

/// AuthService — wraps Supabase Auth operations with error handling.
///
/// BUG FIX (Bug 5): The organization update after sign-up used a hard-coded
/// 500ms delay to wait for the DB trigger to create the coach profile.
/// On slow connections or a busy DB, 500ms is not enough and the update
/// silently fails with no user-visible indication.
/// Fix: Replace the fixed delay with a retry loop (up to 5 attempts, 300ms
/// apart) that polls until the coach row exists before updating.
class AuthService {
  final _supabase = Supabase.instance.client;

  // ── Getters ───────────────────────────────────────────────────────────────

  /// The currently authenticated Supabase user, or null if not signed in.
  User? get currentUser => _supabase.auth.currentUser;

  /// True when a user is currently signed in.
  bool get isLoggedIn => currentUser != null;

  // ── Sign Up ───────────────────────────────────────────────────────────────

  /// Creates a new auth user and waits for the DB trigger to create the
  /// corresponding `coaches` row, then updates `organization` if provided.
  ///
  /// The database trigger `on_auth_user_created` is expected to insert into
  /// `coaches` using the `name` value from `raw_user_meta_data`.
  ///
  /// BUG FIX (Bug 5): Replaced `Future.delayed(500ms)` with a polling loop
  /// that retries up to [_maxTriggerRetries] times at [_triggerRetryDelay]
  /// intervals. This is resilient to slow connections and busy databases.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String name,
    String? organization,
  }) async {
    // Create the auth user. The DB trigger will create the coaches row.
    final response = await _supabase.auth.signUp(
      email: email,
      password: password,
      data: {
        'name': name,
        'organization': organization,
      },
    );

    // If an organization was provided, update the coaches row once the
    // DB trigger has had time to create it.
    if (response.user != null &&
        organization != null &&
        organization.isNotEmpty) {
      await _updateOrganizationWithRetry(response.user!.id, organization);
    }

    return response;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Number of times to poll for the coaches row before giving up.
  static const int _maxTriggerRetries = 5;

  /// Delay between each polling attempt.
  static const Duration _triggerRetryDelay = Duration(milliseconds: 300);

  /// Polls until the `coaches` row for [userId] exists, then writes
  /// [organization] to it.
  ///
  /// If the row never appears within [_maxTriggerRetries] attempts, the
  /// failure is logged but NOT rethrown — sign-up was still successful and
  /// the user can update their organization from a profile screen later.
  Future<void> _updateOrganizationWithRetry(
      String userId, String organization) async {
    for (int attempt = 1; attempt <= _maxTriggerRetries; attempt++) {
      await Future.delayed(_triggerRetryDelay);
      try {
        // Check whether the trigger has created the coaches row yet.
        final existing = await _supabase
            .from('coaches')
            .select('id')
            .eq('user_id', userId)
            .maybeSingle();

        if (existing != null) {
          // Row exists — write the organization.
          await _supabase
              .from('coaches')
              .update({'organization': organization}).eq('user_id', userId);
          return; // Success — stop retrying.
        }
      } catch (e) {
        // Log but continue to next attempt.
        debugPrint('⚠️ Organization update attempt $attempt failed: $e');
      }
    }

    // All attempts exhausted — log a warning. The sign-up is still valid.
    debugPrint(
        '⚠️ Could not update organization after $_maxTriggerRetries attempts. '
        'The coaches trigger may not have run yet.');
  }

  // ── Sign In ───────────────────────────────────────────────────────────────

  /// Signs in with email and password.
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

  /// Returns the `coaches` row for the currently signed-in user, or null.
  Future<Map<String, dynamic>?> getCurrentCoach() async {
    try {
      final userId = currentUser?.id;
      if (userId == null) return null;

      final response = await _supabase
          .from('coaches')
          .select()
          .eq('user_id', userId)
          .single();

      return response;
    } catch (e) {
      debugPrint('Get coach error: $e');
      return null;
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  /// Signs the current user out.
  Future<void> signOut() async {
    await _supabase.auth.signOut();
  }

  // ── Password Reset ────────────────────────────────────────────────────────

  /// Sends a password reset email to [email].
  Future<void> resetPassword(String email) async {
    await _supabase.auth.resetPasswordForEmail(email);
  }

  // ── Auth State Stream ─────────────────────────────────────────────────────

  /// Stream of auth state changes — used by [AuthWrapper] to react to
  /// sign-in and sign-out events.
  Stream<AuthState> get authStateChanges => _supabase.auth.onAuthStateChange;
}