import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_screen.dart';
import 'team_selection_screen.dart';

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // Show loading while checking auth state
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        // Check if user is logged in
        final session = snapshot.hasData ? snapshot.data!.session : null;

        if (session != null) {
          // User is logged in, show team selection
          return const TeamSelectionScreen();
        } else {
          // User is not logged in, show login screen
          return const LoginScreen();
        }
      },
    );
  }
}