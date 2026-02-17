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
      print('✓ Player added');
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
      print('✓ Player updated');
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

  // BULK UPDATE STATUS
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
      print('✓ Player deleted');
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
      return {'present': 0, 'absent': 0, 'late': 0, 'excused': 0};
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

      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      final response = await _supabase
          .from('team_coaches')
          .select('team_id, is_owner, teams(id, team_name, sport, created_at)')
          .eq('coach_id', coachId);

      final teams = (response as List).map((item) {
        final team = item['teams'];
        return {
          'id': team['id'],
          'team_name': team['team_name'],
          'sport': team['sport'],
          'created_at': team['created_at'],
          'is_owner': item['is_owner'] ?? false,
        };
      }).toList();

      return teams;
    } catch (e) {
      print('Error fetching teams: $e');
      throw Exception('Error fetching teams: $e');
    }
  }

  // CREATE NEW TEAM (creator is automatically owner)
  Future<void> createTeam(String teamName, String sport) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('You must be logged in to create a team.');
      }

      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      final teamResponse = await _supabase
          .from('teams')
          .insert({
            'team_name': teamName,
            'sport': sport,
          })
          .select()
          .single();

      final teamId = teamResponse['id'];

      await _supabase.from('team_coaches').insert({
        'team_id': teamId,
        'coach_id': coachId,
        'role': 'Head Coach',
        'is_owner': true, // Creator is always owner
      });

      print('✓ Team created and coach assigned as owner');
    } catch (e) {
      print('Error creating team: $e');
      throw Exception('Error creating team: $e');
    }
  }

  // UPDATE TEAM (any coach on team can update, not just owners)
  Future<void> updateTeam(String teamId, String teamName, String sport) async {
    try {
      // Check if current user is a coach on this team (not just owner)
      final isCoach = await _isCoachOnTeam(teamId);
      if (!isCoach) {
        throw Exception('Only coaches on this team can edit team details');
      }

      await _supabase
          .from('teams')
          .update({
            'team_name': teamName,
            'sport': sport,
          })
          .eq('id', teamId);
      print('✓ Team updated');
    } catch (e) {
      print('Error updating team: $e');
      throw Exception('Error updating team: $e');
    }
  }

  // Helper to check if user is a coach on the team (not just owner)
  Future<bool> _isCoachOnTeam(String teamId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return false;

      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      final result = await _supabase
          .from('team_coaches')
          .select('id')
          .eq('team_id', teamId)
          .eq('coach_id', coachId)
          .maybeSingle();

      return result != null;
    } catch (e) {
      print('Error checking coach status: $e');
      return false;
    }
  }

  // DELETE TEAM (only owners can delete)
  Future<void> deleteTeam(String teamId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) {
        throw Exception('Only team owners can delete teams');
      }

      await _supabase.from('teams').delete().eq('id', teamId);
      print('✓ Team deleted');
    } catch (e) {
      print('Error deleting team: $e');
      throw Exception('Error deleting team: $e');
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

  // CHECK IF CURRENT USER IS TEAM OWNER
  Future<bool> _isTeamOwner(String teamId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return false;

      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      final result = await _supabase
          .from('team_coaches')
          .select('is_owner')
          .eq('team_id', teamId)
          .eq('coach_id', coachId)
          .maybeSingle();

      return result?['is_owner'] == true;
    } catch (e) {
      print('Error checking owner status: $e');
      return false;
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

  // GET ALL COACHES FOR A TEAM (with ownership info)
  Future<List<Map<String, dynamic>>> getTeamCoaches(String teamId) async {
    try {
      final response = await _supabase
          .from('team_coaches')
          .select('coaches(id, name, email, organization), role, is_owner')
          .eq('team_id', teamId)
          .order('is_owner', ascending: false); // Owners first

      return (response as List).map((item) {
        final coach = item['coaches'];
        return {
          'id': coach['id'],
          'name': coach['name'],
          'email': coach['email'],
          'organization': coach['organization'],
          'role': item['role'],
          'is_owner': item['is_owner'] ?? false,
        };
      }).toList();
    } catch (e) {
      print('Error fetching team coaches: $e');
      throw Exception('Error fetching team coaches: $e');
    }
  }

  // ADD COACH TO TEAM
  Future<void> addCoachToTeam(String teamId, String coachEmail, String role) async {
    try {
      final coachResult = await _supabase
          .from('coaches')
          .select('id')
          .eq('email', coachEmail)
          .maybeSingle();

      if (coachResult == null) {
        throw Exception('No coach found with email: $coachEmail');
      }

      final coachId = coachResult['id'];

      final existing = await _supabase
          .from('team_coaches')
          .select('id')
          .eq('team_id', teamId)
          .eq('coach_id', coachId)
          .maybeSingle();

      if (existing != null) {
        throw Exception('This coach is already on the team');
      }

      await _supabase.from('team_coaches').insert({
        'team_id': teamId,
        'coach_id': coachId,
        'role': role,
        'is_owner': false,
      });

      print('✓ Coach added to team');
    } catch (e) {
      print('Error adding coach: $e');
      throw Exception('Error adding coach: $e');
    }
  }

  // REMOVE COACH FROM TEAM
  Future<void> removeCoachFromTeam(String teamId, String coachId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('Not logged in');

      final currentCoach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final currentCoachId = currentCoach['id'];
      final isRemovingSelf = coachId == currentCoachId;

      if (!isRemovingSelf) {
        final isOwner = await _isTeamOwner(teamId);
        if (!isOwner) {
          throw Exception('Only team owners can remove other coaches');
        }
      }

      final coachToRemove = await _supabase
          .from('team_coaches')
          .select('is_owner')
          .eq('team_id', teamId)
          .eq('coach_id', coachId)
          .single();

      if (coachToRemove['is_owner'] == true) {
        final owners = await _supabase
            .from('team_coaches')
            .select('id')
            .eq('team_id', teamId)
            .eq('is_owner', true);

        if (owners.length <= 1) {
          throw Exception('Cannot remove the only owner. Transfer ownership first.');
        }
      }

      await _supabase
          .from('team_coaches')
          .delete()
          .eq('team_id', teamId)
          .eq('coach_id', coachId);

      print('✓ Coach removed from team');
    } catch (e) {
      print('Error removing coach: $e');
      throw Exception('Error removing coach: $e');
    }
  }

  // TRANSFER OWNERSHIP
  Future<void> transferOwnership(String teamId, String newOwnerId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) {
        throw Exception('Only current owner can transfer ownership');
      }

      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('Not logged in');

      final currentCoach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final currentCoachId = currentCoach['id'];

      await _supabase
          .from('team_coaches')
          .update({'is_owner': false})
          .eq('team_id', teamId)
          .eq('coach_id', currentCoachId);

      await _supabase
          .from('team_coaches')
          .update({'is_owner': true})
          .eq('team_id', teamId)
          .eq('coach_id', newOwnerId);

      print('✓ Ownership transferred');
    } catch (e) {
      print('Error transferring ownership: $e');
      throw Exception('Error transferring ownership: $e');
    }
  }
}