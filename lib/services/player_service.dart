import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sweatdex/models/player.dart';

class PlayerService {
  final _supabase = Supabase.instance.client;

  // ============================================
  // PLAYER OPERATIONS
  // ============================================

  // ADD A NEW PLAYER
  Future<void> addPlayer(Player player) async {
    try {
      await _supabase.from('players').insert(player.toMap());
      print('✓ Player added'); // Added success message for consistency
    } catch (e) {
      print('Error adding player: $e');
      throw Exception('Error adding player: $e');
    }
  }

  // FETCH ALL PLAYERS FOR A SPECIFIC TEAM
  Future<List<Player>> getPlayers(String teamId) async {
    try {
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('name', ascending: true);

      return (response as List).map((data) => Player.fromMap(data)).toList();
    } catch (e) {
      print('Error fetching players: $e');
      throw Exception('Error fetching players: $e');
    }
  }

  // LISTEN TO REAL-TIME ROSTER UPDATES
  Stream<List<Player>> getPlayerStream(String teamId) {
    return _supabase
        .from('players')
        .stream(primaryKey: ['id'])
        .eq('team_id', teamId)
        .order('name', ascending: true)
        .map((maps) {
          // Optional: Add debug logging
          // print('Stream updated: ${maps.length} players');
          return maps.map((map) => Player.fromMap(map)).toList();
        });
  }

  // UPDATE PLAYER
  Future<void> updatePlayer(Player player) async {
    try {
      await _supabase
          .from('players')
          .update(player.toMap())
          .eq('id', player.id);
      print('✓ Player updated'); // Added success message
    } catch (e) {
      print('Error updating player: $e');
      throw Exception('Error updating player: $e');
    }
  }

  // UPDATE PLAYER STATUS
  Future<void> updatePlayerStatus(String playerId, String status) async {
    try {
      await _supabase
          .from('players')
          .update({'status': status})
          .eq('id', playerId);
      print('✓ Player status updated to $status');
    } catch (e) {
      print('Error updating player status: $e');
      throw Exception('Error updating player status: $e');
    }
  }

  // BULK UPDATE STATUS (for marking all present/absent)
  Future<void> bulkUpdateStatus(String teamId, String status) async {
    try {
      await _supabase
          .from('players')
          .update({'status': status})
          .eq('team_id', teamId);
      print('✓ All players status updated to $status');
    } catch (e) {
      print('Error bulk updating status: $e');
      throw Exception('Error bulk updating status: $e');
    }
  }

  // DELETE PLAYER
  Future<void> deletePlayer(String id) async {
    try {
      await _supabase.from('players').delete().eq('id', id);
      print('✓ Player deleted'); // Added success message
    } catch (e) {
      print('Error deleting player: $e');
      throw Exception('Failed to delete player: $e');
    }
  }

  // GET ATTENDANCE SUMMARY
  Future<Map<String, int>> getAttendanceSummary(String teamId) async {
    try {
      final players = await getPlayers(teamId);
      
      final summary = {
        'present': 0,
        'absent': 0,
        'late': 0,
        'excused': 0,
      };
      
      for (var player in players) {
        summary[player.status] = (summary[player.status] ?? 0) + 1;
      }
      
      return summary;
    } catch (e) {
      print('Error getting attendance summary: $e');
      return {'present': 0, 'absent': 0, 'late': 0, 'excused': 0}; // Return default values instead of empty map
    }
  }

  // ============================================
  // TEAM OPERATIONS
  // ============================================

  // GET ALL TEAMS FOR CURRENT COACH
  Future<List<Map<String, dynamic>>> getTeams() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        print('No user logged in');
        return [];
      }

      // Get coach profile
      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      // Get teams for this coach via team_coaches junction table
      final response = await _supabase
          .from('team_coaches')
          .select('team_id, teams(id, team_name, sport, created_at)')
          .eq('coach_id', coachId);

      // Extract team data from the nested response
      final teams = (response as List).map((item) {
        final team = item['teams'];
        return {
          'id': team['id'],
          'team_name': team['team_name'],
          'sport': team['sport'],
          'created_at': team['created_at'],
        };
      }).toList();

      return teams;
    } catch (e) {
      print('Error fetching teams: $e');
      throw Exception('Error fetching teams: $e');
    }
  }

  // CREATE NEW TEAM
  Future<void> createTeam(String teamName, String sport) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('You must be logged in to create a team.');
      }

      // Get coach profile
      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      // 1. Create the team
      final teamResponse = await _supabase
          .from('teams')
          .insert({
            'team_name': teamName,
            'sport': sport,
          })
          .select()
          .single();

      final teamId = teamResponse['id'];

      // 2. Link coach to team in team_coaches junction table
      await _supabase.from('team_coaches').insert({
        'team_id': teamId,
        'coach_id': coachId,
        'role': 'Head Coach',
      });

      print('✓ Team created and coach assigned');
    } catch (e) {
      print('Error creating team: $e');
      throw Exception('Error creating team: $e');
    }
  }

  // GET TEAM DETAILS
  Future<Map<String, dynamic>?> getTeam(String teamId) async {
    try {
      final response = await _supabase
          .from('teams')
          .select()
          .eq('id', teamId)
          .single();

      return response;
    } catch (e) {
      print('Error fetching team: $e');
      return null;
    }
  }

  // DELETE TEAM
  Future<void> deleteTeam(String teamId) async {
    try {
      await _supabase.from('teams').delete().eq('id', teamId);
      print('✓ Team deleted');
    } catch (e) {
      print('Error deleting team: $e');
      throw Exception('Error deleting team: $e');
    }
  }

  // ============================================
  // COACH OPERATIONS
  // ============================================

  // GET CURRENT COACH PROFILE
  Future<Map<String, dynamic>?> getCurrentCoach() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return null;

      final response = await _supabase
          .from('coaches')
          .select()
          .eq('user_id', user.id)
          .single();

      return response;
    } catch (e) {
      print('Error fetching coach: $e');
      return null;
    }
  }

  // GET ALL COACHES FOR A TEAM
  Future<List<Map<String, dynamic>>> getTeamCoaches(String teamId) async {
    try {
      final response = await _supabase
          .from('team_coaches')
          .select('coaches(id, name, email, organization), role')
          .eq('team_id', teamId);

      return (response as List).map((item) {
        final coach = item['coaches'];
        return {
          'id': coach['id'],
          'name': coach['name'],
          'email': coach['email'],
          'organization': coach['organization'],
          'role': item['role'],
        };
      }).toList();
    } catch (e) {
      print('Error fetching team coaches: $e');
      throw Exception('Error fetching team coaches: $e');
    }
  }
}
