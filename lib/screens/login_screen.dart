import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'team_selection_screen.dart';

/// LoginScreen — handles both Sign In and Sign Up flows.
///
/// BUG FIX (Bug 6): Toggling between Sign In and Sign Up modes previously
/// called `_formKey.currentState?.reset()` which only resets validator
/// display state. The TextEditingControllers retained their text, meaning
/// hidden fields (name, organization) kept their values. On toggle-back, those
/// values would be included in the next submission.
/// Fix: Explicitly clear all controllers when toggling modes.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _authService = AuthService();
  final _formKey = GlobalKey<FormState>();

  // Text input controllers for all fields.
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _organizationController = TextEditingController();

  bool _isLoading = false;
  bool _isSignUp = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _organizationController.dispose();
    super.dispose();
  }

  /// Returns true if the password meets the strength requirement:
  /// must contain at least one letter and one number.
  bool _isPasswordStrong(String password) {
    final hasLetter = password.contains(RegExp(r'[a-zA-Z]'));
    final hasNumber = password.contains(RegExp(r'[0-9]'));
    return hasLetter && hasNumber;
  }

  /// Handles both sign-in and sign-up submission.
  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      if (_isSignUp) {
        await _authService.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          name: _nameController.text.trim(),
          organization: _organizationController.text.trim().isEmpty
              ? null
              : _organizationController.text.trim(),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          // Switch back to Sign In mode after successful registration.
          _toggleMode();
        }
      } else {
        await _authService.signIn(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => const TeamSelectionScreen(),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_getErrorMessage(e.toString())),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Maps raw Supabase/auth error strings to user-friendly messages.
  String _getErrorMessage(String error) {
    if (error.contains('email rate limit exceeded') ||
        error.contains('over_email_send_rate_limit')) {
      return 'Too many attempts. Please wait an hour or use a different email.';
    } else if (error.contains('Invalid login credentials')) {
      return 'Invalid email or password';
    } else if (error.contains('Email not confirmed')) {
      return 'Please verify your email before signing in';
    } else if (error.contains('User already registered')) {
      return 'This email is already registered. Try signing in instead.';
    } else if (error.contains('Password should be at least')) {
      return 'Password must be at least 6 characters';
    } else if (error.contains('unable to validate email address') ||
        error.contains('Invalid email')) {
      return 'Please enter a valid email address';
    } else if (error.contains('Database error') || error.contains('23505')) {
      return 'Database error. Please contact support.';
    }
    return 'An error occurred. Please try again.';
  }

  /// Sends a password reset email to the address in the email field.
  Future<void> _handleForgotPassword() async {
    if (_emailController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your email address')),
      );
      return;
    }

    try {
      await _authService.resetPassword(_emailController.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password reset link sent! Check your email.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    }
  }

  /// Toggles between Sign In and Sign Up modes.
  ///
  /// BUG FIX (Bug 6): Now explicitly clears all TextEditingControllers in
  /// addition to resetting the form's validation state. This prevents hidden
  /// fields (name, organization) from retaining stale values across mode
  /// switches, which would have been silently included in the next submission.
  void _toggleMode() {
    setState(() {
      _isSignUp = !_isSignUp;
      // Reset validation state.
      _formKey.currentState?.reset();
      // FIX (Bug 6): Clear controller text — reset() does NOT do this.
      _emailController.clear();
      _passwordController.clear();
      _nameController.clear();
      _organizationController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // App icon.
                    Icon(
                      Icons.sports,
                      size: 80,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),

                    // Screen title.
                    Text(
                      _isSignUp ? 'Create Account' : 'Welcome Back',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isSignUp
                          ? 'Sign up to manage your teams'
                          : 'Sign in to continue',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey[600],
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),

                    // ── Sign-up-only fields ───────────────────────────────
                    if (_isSignUp) ...[
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            FocusScope.of(context).nextFocus(),
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          prefixIcon: Icon(Icons.person),
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (_isSignUp &&
                              (value == null || value.trim().isEmpty)) {
                            return 'Please enter your name';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _organizationController,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            FocusScope.of(context).nextFocus(),
                        decoration: const InputDecoration(
                          labelText: 'Organization (optional)',
                          hintText: 'e.g., Lincoln High School',
                          prefixIcon: Icon(Icons.business),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ── Email field ───────────────────────────────────────
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) =>
                          FocusScope.of(context).nextFocus(),
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email),
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter your email';
                        }
                        if (!value.contains('@')) {
                          return 'Please enter a valid email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // ── Password field ────────────────────────────────────
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      // Submit form on keyboard "done" action.
                      onFieldSubmitted: (_) => _handleSubmit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility
                                : Icons.visibility_off,
                          ),
                          onPressed: () {
                            setState(
                                () => _obscurePassword = !_obscurePassword);
                          },
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your password';
                        }
                        if (_isSignUp && value.length < 8) {
                          return 'Password must be at least 8 characters';
                        }
                        if (_isSignUp && !_isPasswordStrong(value)) {
                          return 'Password must include letters and numbers';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),

                    // ── Forgot password (sign-in only) ────────────────────
                    if (!_isSignUp)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _handleForgotPassword,
                          child: const Text('Forgot Password?'),
                        ),
                      ),
                    const SizedBox(height: 24),

                    // ── Submit button ─────────────────────────────────────
                    FilledButton(
                      onPressed: _isLoading ? null : _handleSubmit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(_isSignUp ? 'Sign Up' : 'Sign In'),
                    ),
                    const SizedBox(height: 16),

                    // ── Mode toggle ───────────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _isSignUp
                              ? 'Already have an account?'
                              : "Don't have an account?",
                        ),
                        TextButton(
                          // FIX (Bug 6): Use _toggleMode() which clears
                          // controllers, instead of an inline setState that
                          // only reset validation state.
                          onPressed: _toggleMode,
                          child:
                              Text(_isSignUp ? 'Sign In' : 'Sign Up'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}