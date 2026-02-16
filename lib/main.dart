import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart'; // Add this
import 'package:flutter_dotenv/flutter_dotenv.dart';      // Add this
import 'screens/team_selection_screen.dart';

void main() async {
  // 1. Ensure Flutter is ready to talk to the device
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Load your environment variables from the .env file
  await dotenv.load(fileName: ".env");

  // 3. Initialize Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true, 
        colorSchemeSeed: Colors.blue, // You can change this to your team color!
      ),
      // IMPORTANT: Replace this placeholder with a UUID from your 'teams' table
      home: const TeamSelectionScreen(),
    );
  }

}