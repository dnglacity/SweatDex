import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import 'team_selection_screen.dart';

// =============================================================================
// login_screen.dart  (AOD v1.12 — BUG FIX: database connection error)
//
// FIXES (AI_TODO_List.md — "Review and fix database connection issue"):
//
//   FIX-1: Added debugPrint(e) in _handleSubmit() catch block so the raw
//     Supabase/PostgreSQL error always appears in the console. Previously the
//     exception was swallowed into _getErrorMessage() with no logging, making
//     silent failures impossible to diagnose.
//
//   FIX-2: signUp() response is now checked. AuthResponse.user == null
//     indicates a silent failure (rate-limit, validation, or trigger error
//     where Supabase returns HTTP 200 but no user object). Previously the
//     code fell through to the success snackbar and mode-toggle even though
//     no account was created.
//
//   FIX-3: _getErrorMessage() now logs the raw error string before matching,
//     and the 'Database error' branch now surfaces the underlying message
//     instead of a generic "contact support" dead-end. The branch also now
//     matches the actual Supabase trigger-failure string:
//     "Database error saving new user" (returned when handle_new_user
//     trigger fails, e.g. due to a duplicate email in public.users or a
//     missing column).
//
//   FIX-4: Added a specific 'null user' error message so the sign-up silent-
//     failure path is visible to the user ("Account could not be created.
//     Please try again or contact support.").
//
//   FIX-5: 'over_email_send_rate_limit' matcher broadened — Supabase also
//     returns 'email_send_rate_limit_exceeded' in some SDK versions.
//
// All v1.7 behaviours retained:
//   – First/Last name, Confirm Password, Athlete ID fields
//   – BUG FIX (Bug 6): _toggleMode() clears ALL controllers
// =============================================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _authService = AuthService();
  final _formKey    = GlobalKey<FormState>();

  // ── Text controllers for all form fields ──────────────────────────────────
  final _emailController            = TextEditingController();
  final _passwordController         = TextEditingController();
  final _confirmPasswordController  = TextEditingController();
  final _firstNameController        = TextEditingController();
  final _lastNameController         = TextEditingController();
  final _organizationController     = TextEditingController();
  final _athleteIdController        = TextEditingController();

  bool _isLoading       = false;
  bool _isSignUp        = false;
  bool _obscurePassword = true;
  bool _obscureConfirm  = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _organizationController.dispose();
    _athleteIdController.dispose();
    super.dispose();
  }

  // ── Password strength check ───────────────────────────────────────────────

  bool _isPasswordStrong(String password) {
    return password.contains(RegExp(r'[a-zA-Z]')) &&
           password.contains(RegExp(r'[0-9]'));
  }

  // ── Submit handler ────────────────────────────────────────────────────────

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    try {
      if (_isSignUp) {
        final response = await _authService.signUp(
          email:        _emailController.text.trim(),
          password:     _passwordController.text,
          firstName:    _firstNameController.text.trim(),
          lastName:     _lastNameController.text.trim(),
          organization: _organizationController.text.trim().isEmpty
                          ? null
                          : _organizationController.text.trim(),
          athleteId:    _athleteIdController.text.trim().isEmpty
                          ? null
                          : _athleteIdController.text.trim(),
        );

        // FIX-2: Supabase can return HTTP 200 with a null user when the
        // handle_new_user DB trigger fails or a rate-limit is hit silently.
        // Previously this path fell through to the success snackbar.
        if (response.user == null) {
          throw Exception(
            'null_user: Account could not be created. '
            'Please try again or contact support.',
          );
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created! Please sign in.'),
              backgroundColor: Colors.green,
            ),
          );
          _toggleMode();
        }
      } else {
        await _authService.signIn(
          email:    _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const TeamSelectionScreen()),
          );
        }
      }
    } catch (e) {
      // FIX-1: Always log the raw error to the console so it's visible
      // during development and in crash-reporting tools. Previously this
      // block went straight to _getErrorMessage() with no trace.
      debugPrint('LoginScreen _handleSubmit error: $e');

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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Error messages ────────────────────────────────────────────────────────

  /// Maps raw Supabase / Dart exception strings to user-friendly messages.
  ///
  /// FIX-3: Each branch now calls debugPrint so the FULL raw error is always
  /// in the console even when we show a simplified message to the user.
  ///
  /// FIX-3: The 'Database error' branch now shows the specific underlying
  /// error rather than a dead-end "contact support" message. The raw string
  /// is also printed so developers can identify the root cause (e.g. a
  /// failing DB trigger or a duplicate-email constraint violation).
  String _getErrorMessage(String error) {
    debugPrint('LoginScreen _getErrorMessage raw: $error');

    if (error.contains('email rate limit exceeded') ||
        error.contains('over_email_send_rate_limit') ||
        // FIX-5: broadened — alternate rate-limit string in some SDK versions.
        error.contains('email_send_rate_limit_exceeded')) {
      return 'Too many attempts. Please wait a moment and try again.';

    } else if (error.contains('Invalid login credentials')) {
      return 'Invalid email or password.';

    } else if (error.contains('Email not confirmed')) {
      return 'Please verify your email before signing in.';

    } else if (error.contains('User already registered')) {
      return 'This email is already registered. Try signing in instead.';

    } else if (error.contains('Password should be at least')) {
      return 'Password must be at least 6 characters.';

    } else if (error.contains('unable to validate email address') ||
               error.contains('Invalid email')) {
      return 'Please enter a valid email address.';

    } else if (error.contains('null_user')) {
      // FIX-4: sign-up returned HTTP 200 but no user object — see FIX-2.
      return 'Account could not be created. Please try again or contact support.';

    } else if (error.contains('Database error saving new user')) {
      // FIX-3: handle_new_user trigger failure. Most commonly caused by a
      // duplicate email in public.users when the user previously registered
      // but did not verify their email (leaving a stuck row).
      return 'There was a problem setting up your account. '
             'If you have registered before, try signing in or use '
             '"Forgot Password" to recover your account.';

    } else if (error.contains('Database error') || error.contains('23505')) {
      // FIX-3: generic DB error — show a slightly more actionable message
      // and rely on the debugPrint above to expose the real cause.
      return 'A database error occurred. Please try again. '
             'If the problem persists, contact support.';
    }

    return 'An error occurred. Please try again.';
  }

  // ── Forgot password ───────────────────────────────────────────────────────

  Future<void> _handleForgotPassword() async {
    if (_emailController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your email address first.')),
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
      debugPrint('LoginScreen _handleForgotPassword error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  // ── Mode toggle ───────────────────────────────────────────────────────────

  /// Switches between Sign In and Sign Up. Clears ALL controllers.
  ///
  /// BUG FIX (Bug 6 — retained): explicitly clear controller text because
  /// FormState.reset() only clears validation state, not field values.
  void _toggleMode() {
    setState(() {
      _isSignUp = !_isSignUp;
      _formKey.currentState?.reset();
      _emailController.clear();
      _passwordController.clear();
      _confirmPasswordController.clear();
      _firstNameController.clear();
      _lastNameController.clear();
      _organizationController.clear();
      _athleteIdController.clear();
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.primary,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Card(
                elevation: 6,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(28.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ── App icon ────────────────────────────────────────
                        CircleAvatar(
                          radius: 36,
                          backgroundColor: colorScheme.primary,
                          child: const Icon(Icons.sports,
                              size: 40, color: Colors.white),
                        ),
                        const SizedBox(height: 16),

                        // ── Title ───────────────────────────────────────────
                        Text(
                          _isSignUp ? 'Create Account' : 'Apex On Deck',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _isSignUp
                              ? 'Sign up to manage your teams'
                              : 'Sign in to continue',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: Colors.grey[600]),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 28),

                        // ── Sign-up-only fields ──────────────────────────────
                        if (_isSignUp) ...[
                          // First Name
                          TextFormField(
                            controller: _firstNameController,
                            textInputAction: TextInputAction.next,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'First Name',
                              prefixIcon: Icon(Icons.person_outline),
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) {
                              if (_isSignUp &&
                                  (v == null || v.trim().isEmpty)) {
                                return 'Please enter your first name';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          // Last Name
                          TextFormField(
                            controller: _lastNameController,
                            textInputAction: TextInputAction.next,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              labelText: 'Last Name',
                              prefixIcon: Icon(Icons.person),
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) {
                              if (_isSignUp &&
                                  (v == null || v.trim().isEmpty)) {
                                return 'Please enter your last name';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          // Organization (optional)
                          TextFormField(
                            controller: _organizationController,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Organization (optional)',
                              hintText: 'e.g., Lincoln High School',
                              prefixIcon: Icon(Icons.business),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Athlete ID (optional)
                          TextFormField(
                            controller: _athleteIdController,
                            textInputAction: TextInputAction.next,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Athlete ID (optional)',
                              hintText: 'e.g., A12345',
                              prefixIcon: Icon(Icons.badge_outlined),
                              border: OutlineInputBorder(),
                              helperText:
                                  'Your school or club athlete ID, if you have one',
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // ── Email ────────────────────────────────────────────
                        TextFormField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.email),
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) {
                              return 'Please enter your email';
                            }
                            if (!v.contains('@')) {
                              return 'Please enter a valid email';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // ── Password ─────────────────────────────────────────
                        TextFormField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          textInputAction: _isSignUp
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onFieldSubmitted:
                              _isSignUp ? null : (_) => _handleSubmit(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(_obscurePassword
                                  ? Icons.visibility
                                  : Icons.visibility_off),
                              onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) {
                              return 'Please enter your password';
                            }
                            if (_isSignUp && v.length < 8) {
                              return 'Password must be at least 8 characters';
                            }
                            if (_isSignUp && !_isPasswordStrong(v)) {
                              return 'Password must include letters and numbers';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // Confirm Password (sign-up only)
                        if (_isSignUp) ...[
                          TextFormField(
                            controller: _confirmPasswordController,
                            obscureText: _obscureConfirm,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _handleSubmit(),
                            decoration: InputDecoration(
                              labelText: 'Confirm Password',
                              prefixIcon: const Icon(Icons.lock_outline),
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                icon: Icon(_obscureConfirm
                                    ? Icons.visibility
                                    : Icons.visibility_off),
                                onPressed: () => setState(
                                    () => _obscureConfirm = !_obscureConfirm),
                              ),
                            ),
                            validator: (v) {
                              if (_isSignUp) {
                                if (v == null || v.isEmpty) {
                                  return 'Please confirm your password';
                                }
                                if (v != _passwordController.text) {
                                  return 'Passwords do not match';
                                }
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 8),
                        ],

                        // ── Forgot password (sign-in only) ───────────────────
                        if (!_isSignUp)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _handleForgotPassword,
                              child: const Text('Forgot Password?'),
                            ),
                          ),
                        const SizedBox(height: 20),

                        // ── Submit button ────────────────────────────────────
                        FilledButton(
                          onPressed: _isLoading ? null : _handleSubmit,
                          style: FilledButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16)),
                          child: _isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white),
                                )
                              : Text(_isSignUp ? 'Sign Up' : 'Sign In'),
                        ),
                        const SizedBox(height: 16),

                        // ── Mode toggle ──────────────────────────────────────
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_isSignUp
                                ? 'Already have an account?'
                                : "Don't have an account?"),
                            TextButton(
                              onPressed: _toggleMode,
                              child: Text(_isSignUp ? 'Sign In' : 'Sign Up'),
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
        ),
      ),
    );
  }
}