import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_screen.dart';
import 'team_selection_screen.dart';
import 'reset_password_screen.dart'; // NEW — see below

// =============================================================================
// auth_wrapper.dart  (AOD v1.10)
//
// CHANGE (v1.10 — password recovery routing):
//   When the user follows a password-reset link, Supabase emits
//   AuthChangeEvent.passwordRecovery. Previously this was treated like a
//   normal sign-in and the user was sent directly to TeamSelectionScreen
//   without being shown the new-password form.
//
//   Fix: detect the passwordRecovery event and route to ResetPasswordScreen
//   instead. The screen (new file) lets the user enter and confirm a new
//   password, then navigates back to TeamSelectionScreen on success.
// =============================================================================

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      // Listen to the Supabase auth state stream for the lifetime of the widget.
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {

        // Show a loading spinner while the initial auth state is being resolved.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          debugPrint('AuthWrapper stream error: ${snapshot.error}');
          return const LoginScreen();
        }

        final authState = snapshot.data;
        final session   = authState?.session;

        // CHANGE (v1.10): detect password recovery event and route to the
        // dedicated reset screen instead of treating it as a normal login.
        if (authState?.event == AuthChangeEvent.passwordRecovery) {
          return const ResetPasswordScreen();
        }

        if (session != null) {
          // Normal authenticated session → show team selection.
          return const TeamSelectionScreen();
        } else {
          // Not authenticated → show login/signup.
          return const LoginScreen();
        }
      },
    );
  }
}