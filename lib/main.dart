import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/auth_wrapper.dart'; 


void main() async {
  // Ensure Flutter is ready
  WidgetsFlutterBinding.ensureInitialized();
  print('✓ Flutter binding initialized');

  try {
    
    
  

    
    // Check if environment variables are loaded
    const supabaseUrl = String.fromEnvironment('https://pxxpvhhezmbtbfeoibua.supabase.co');
    const supabaseAnonKey = String.fromEnvironment('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB4eHB2aGhlem1idGJmZW9pYnVhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzExO');

    print('SUPABASE_URL: $supabaseUrl');
    print('SUPABASE_ANON_KEY: ${supabaseAnonKey?.substring(0, 20)}...');


    // Initialize Supabase
    print('Initializing Supabase...');
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
    print('✓ Supabase initialized');

    print('Starting app...');
    runApp(const MyApp());
  } catch (e) {
    print('❌ ERROR: $e');
    // Show error if initialization fails
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
                  'Initialization Error',
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const AuthWrapper(),
    );
  }
}