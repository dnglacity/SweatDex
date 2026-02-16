import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/player.dart';

class PlayerService {
  final _supabase = Supabase.instance.client;

  // 1. ADD A NEW PLAYER
  Future<void> addPlayer(Player player) async {
    try {
      // We use the toMap() helper we built in player.dart
      await _supabase.from('players').insert(player.toMap());
    } catch (e) {
      throw Exception('Error adding player: $e');
    }
  }

  // 2. FETCH ALL PLAYERS FOR A SPECIFIC TEAM (One-time fetch)
  Future<List<Player>> getPlayers(String teamId) async {
    try {
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('display_name', ascending: true);

      // Convert the raw data list into a list of Player objects
      return (response as List).map((data) => Player.fromMap(data)).toList();
    } catch (e) {
      throw Exception('Error fetching players: $e');
    }
  }

  // 3. LISTEN TO REAL-TIME ROSTER UPDATES (The "Magic" part)
  // This creates a continuous stream of data
  Stream<List<Player>> getPlayerStream(String teamId) {
    return _supabase
        .from('players')
        .stream(primaryKey: ['id'])
        .eq('team_id', teamId)
        .order('display_name', ascending: true)
        .map((maps) => maps.map((map) => Player.fromMap(map)).toList());
  }

  Future<void> updatePlayer(Player player) async {
    try {
      await _supabase
        .from('players')
        .update(player.toMap()) // Use the same map logic as Add
        .eq('id', player.id);   // IMPORTANT: Only update this specific player
    } catch (e) {
    throw Exception('Error updating player: $e');
    }
  }

  Future<void> deletePlayer(String id) async {
    try {
    // This tells Supabase: "Go to the players table, 
    // find the row where the 'id' matches this ID, and delete it."
      await _supabase
        .from('players')
        .delete()
        .eq('id', id); 
    } catch (e) {
    // [Inference] If this fails, it's likely due to RLS policies 
    // or a connection issue.
      throw Exception('Failed to delete player: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getTeams() async {
    try {
      final List<Map<String, dynamic>> response = await _supabase
        .from('teams')
        .select();
        
      return response;
    } catch (e) {
      throw Exception('Error fetching teams: $e');
    }
  }

  Future<void> createTeam(String teamName, String sport) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('You must be logged in to create a team.');

      await _supabase.from('teams').insert({
        'team_name': teamName,
        'sport': sport,
        'coach_id': user.id, // Links the team to the current coach
      });
    } catch (e) {
      throw Exception('Error creating team: $e');
    }
  }

}