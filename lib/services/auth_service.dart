import 'package:supabase_flutter/supabase_flutter.dart';

class AuthService {
  final _supabase = Supabase.instance.client;

  // Get current user
  User? get currentUser => _supabase.auth.currentUser;

  // Check if user is logged in
  bool get isLoggedIn => currentUser != null;

  // Sign up with email and password
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String name,
    String? organization,
  }) async {
    try {
      print('=== STARTING SIGNUP ===');
      print('Email: $email');
      print('Name: $name');
      print('Organization: $organization');
      
      print('Creating auth user...');
      
      // Create auth user with metadata
      // The database trigger will automatically create the coach profile
      final response = await _supabase.auth.signUp(
        email: email,
        password: password,
        data: {
          'name': name,
          'organization': organization, // Include organization in metadata
        },
      );

      print('Auth user created: ${response.user?.id}');
      
      // Optional: Update organization if provided and trigger didn't handle it
      if (response.user != null && organization != null && organization.isNotEmpty) {
        print('Updating coach organization...');
        try {
          // Wait a moment for trigger to complete
          await Future.delayed(const Duration(milliseconds: 500));
          
          await _supabase
              .from('coaches')
              .update({'organization': organization})
              .eq('user_id', response.user!.id);
          print('✓ Organization updated');
        } catch (e) {
          print('⚠️ Could not update organization: $e');
          // Don't rethrow - signup was still successful
        }
      }

      print('✓ Sign up completed');
      return response;
    } on AuthException catch (e) {
      print('❌ AuthException: ${e.message}');
      print('Status code: ${e.statusCode}');
      rethrow;
    } catch (e) {
      print('❌ Unknown error in signUp: $e');
      rethrow;
    }
  }

  // Sign in with email and password
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );
      return response;
    } on AuthException catch (e) {
      print('❌ AuthException: ${e.message}');
      print('Status code: ${e.statusCode}');
      rethrow;
    } catch (e) {
      print('❌ Unknown error in signIn: $e');
      rethrow;
    }
  }

  // Get current coach profile
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
      print('Get coach error: $e');
      return null;
    }
  }

  // Sign out
  Future<void> signOut() async {
    try {
      await _supabase.auth.signOut();
    } catch (e) {
      print('Sign out error: $e');
      rethrow;
    }
  }

  // Reset password
  Future<void> resetPassword(String email) async {
    try {
      await _supabase.auth.resetPasswordForEmail(email);
    } catch (e) {
      print('Reset password error: $e');
      rethrow;
    }
  }

  // Listen to auth state changes
  Stream<AuthState> get authStateChanges => _supabase.auth.onAuthStateChange;
}