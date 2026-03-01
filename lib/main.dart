import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/auth_wrapper.dart';

// ─────────────────────────────────────────────────────────────────────────────
// main.dart
//
// App entry point. Initialises Supabase from compile-time environment
// variables injected via --dart-define-from-file=config.json.
//
// CHANGE (Notes.txt): Color palette updated to Blue and Gold.
//   • Primary:   Deep Blue  (#1A3A6B)
//   • Secondary: Gold       (#F4C430)
//   The colorScheme is built manually with ColorScheme.fromSeed so that
//   Material 3 tonal surfaces stay on-brand.
// ─────────────────────────────────────────────────────────────────────────────

const kAppVersion = '1.12';

void main() async {
  // Ensure Flutter bindings are ready before any async work.
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Read compile-time environment variables.
    const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
    const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      throw Exception(
        'Missing Supabase configuration! '
        'Ensure you are building with --dart-define-from-file=config.json',
      );
    }

    // Initialise the Supabase client once for the lifetime of the app.
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );

    runApp(const MyApp());
  } catch (e) {
    // If initialisation fails show a clear error screen instead of a blank app.
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  'Initialisation Error',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  e.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // ── Brand colors ────────────────────────────────────────────────────────────
  // CHANGE (Notes.txt): Blue and Gold palette.
  static const Color _brandBlue = Color(0xFF1A3A6B); // Deep Navy Blue
  static const Color _brandGold = Color(0xFFF4C430); // Championship Gold

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Apex On Deck',
      theme: ThemeData(
        useMaterial3: true,
        // Build a full Material 3 color scheme from the brand seed.
        // Override the key surfaces so both blue and gold appear naturally.
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brandBlue,
          brightness: Brightness.light,
        ).copyWith(
          // Primary actions, AppBar background, FABs → deep blue.
          primary: _brandBlue,
          onPrimary: Colors.white,
          // Secondary accents (chips, subs zone highlight) → gold.
          secondary: _brandGold,
          onSecondary: Colors.black,
          // Primary container (avatars, tag backgrounds) → light blue tint.
          primaryContainer: const Color(0xFFD6E4FF),
          onPrimaryContainer: _brandBlue,
          // Secondary container → light gold tint.
          secondaryContainer: const Color(0xFFFFF3CD),
          onSecondaryContainer: const Color(0xFF5C4A00),
        ),
        // AppBar uses the primary (blue) color.
        appBarTheme: const AppBarTheme(
          backgroundColor: _brandBlue,
          foregroundColor: Colors.white,
          elevation: 2,
          centerTitle: true,
          iconTheme: IconThemeData(color: Colors.white),
        ),
        // FABs use secondary (gold).
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: _brandGold,
          foregroundColor: Colors.black,
        ),
        // Filled buttons use primary (blue).
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _brandBlue,
            foregroundColor: Colors.white,
          ),
        ),
        // Card subtle shadow.
        cardTheme: const CardThemeData(
          elevation: 2,
          margin: EdgeInsets.zero,
        ),
      ),
      home: const AuthWrapper(),
    );
  }
}